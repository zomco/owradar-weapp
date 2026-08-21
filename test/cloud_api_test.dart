/// CloudApi 的契约测试。
///
/// 用 MockClient 拦住 HTTP，断言**线格式**而不是内部实现：
/// 路径、方法、请求体字段名、鉴权头，以及错误码的翻译。
/// 这些是与 mmradar-server 的接口约定，改动必须先改服务端 README §4。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mmradar_app/core/contracts/command.dart';
import 'package:mmradar_app/data/cloud_api.dart';

/// 构造一条服务端响应。
///
/// 刻意用 bytes 而不是字符串：`http.Response(String, ...)` 会按
/// Content-Type 里的 charset 编码，缺省是 latin-1，中文直接抛异常。
/// 真实服务端也可能不写 charset，所以这里就按「只有 application/json、
/// 没有 charset」来发，正好压住 CloudApi 必须按 UTF-8 解码这条约束。
http.Response _res(Object? json, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(json)),
  status,
  headers: {'content-type': 'application/json'},
);

/// 记录最后一次请求，方便断言线格式。
class _Recorder {
  http.Request? last;

  MockClient client(Map<String, Object?> Function(http.Request) handler, {int status = 200}) {
    return MockClient((req) async {
      last = req;
      return _res(handler(req), status);
    });
  }
}

void main() {
  group('账号', () {
    test('请求验证码不带 Authorization —— 此时还没有 token', () async {
      final rec = _Recorder();
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'stale',
        client: rec.client((_) => {'dev_code': '123456'}),
      );

      final code = await api.requestOtp('a@b.c');

      expect(code, '123456');
      expect(rec.last!.method, 'POST');
      expect(rec.last!.url.path, '/v1/auth/otp');
      expect(rec.last!.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(rec.last!.body), {'email': 'a@b.c'});
    });

    test('验证成功后自动记住 access token', () async {
      final rec = _Recorder();
      final api = CloudApi(
        baseUrl: 'http://x',
        client: rec.client(
          (_) => {'access_token': 'AAA', 'refresh_token': 'RRR', 'expires_in': 900},
        ),
      );

      final tokens = await api.verifyOtp('a@b.c', '123456');

      expect(tokens.access, 'AAA');
      expect(tokens.refresh, 'RRR');
      // 后续调用不必手动传 token
      expect(api.accessToken, 'AAA');
    });

    test('服务端没给 token 时报内部错误，而不是静默当成功', () async {
      final api = CloudApi(
        baseUrl: 'http://x',
        client: MockClient((_) async => _res(<String, Object?>{})),
      );

      await expectLater(api.verifyOtp('a@b.c', '000000'), throwsA(isA<CloudException>()));
    });
  });

  group('鉴权头', () {
    test('有 token 时带上 Bearer', () async {
      final rec = _Recorder();
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'TOK',
        client: rec.client((_) => {'devices': []}),
      );

      await api.listDevices();

      expect(rec.last!.headers['Authorization'], 'Bearer TOK');
    });

    test('token 改写后立刻生效 —— 刷新会话不必重建 CloudApi', () async {
      final rec = _Recorder();
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'OLD',
        client: rec.client((_) => {'devices': []}),
      );

      api.accessToken = 'NEW';
      await api.listDevices();

      expect(rec.last!.headers['Authorization'], 'Bearer NEW');
    });
  });

  group('设备', () {
    test('列表解析出在线判断', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final api = CloudApi(
        baseUrl: 'http://x',
        client: MockClient(
          (_) async => _res({
              'devices': [
                {'id': 'd1', 'name': '书房', 'last_seen_at': now - 10},
                {'id': 'd2', 'name': '工位', 'last_seen_at': now - 4000},
                {'id': 'd3', 'name': '新的'},
              ],
            }, 200),
        ),
      );

      final list = await api.listDevices();

      expect(list.map((d) => d.id), ['d1', 'd2', 'd3']);
      expect(list[0].looksOnline, isTrue);
      expect(list[1].looksOnline, isFalse);
      // 从未上线过不能当成在线
      expect(list[2].looksOnline, isFalse);
    });

    test('配对码统一转大写 —— 用户手输小写也要能过', () async {
      final rec = _Recorder();
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'T',
        client: rec.client(
          (_) => {
            'device': {'id': 'd9', 'name': '桌面助理'},
          },
        ),
      );

      final d = await api.pair('abcd1234');

      expect(d.id, 'd9');
      expect(jsonDecode(rec.last!.body), {'code': 'ABCD1234'});
    });

    test('删除规则不发请求体 —— DELETE 带 body 有些代理会拒', () async {
      final rec = _Recorder();
      final api = CloudApi(baseUrl: 'http://x', accessToken: 'T', client: rec.client((_) => {}));

      await api.deleteRule('d1', 'rule_co2_high');

      expect(rec.last!.method, 'DELETE');
      expect(rec.last!.url.path, '/v1/devices/d1/rules/rule_co2_high');
      expect(rec.last!.body, isEmpty);
    });
  });

  group('错误翻译', () {
    test('服务端结构化错误原样带出错误码', () async {
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'T',
        client: MockClient(
          (_) async => _res({
              'error': {'code': 'not_found', 'message': '配对码无效或已过期'},
            }, 404),
        ),
      );

      await expectLater(
        api.pair('BADCODE0'),
        throwsA(isA<CloudException>().having((e) => e.error.code, 'code', ErrorCode.notFound)),
      );
    });

    test('非结构化错误按状态码兜底', () async {
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'T',
        client: MockClient((_) async => http.Response.bytes(utf8.encode('<html>502</html>'), 401)),
      );

      await expectLater(
        api.listDevices(),
        throwsA(isA<CloudException>().having((e) => e.error.code, 'code', ErrorCode.unauthorized)),
      );
    });

    test('网络异常归到 transport，而不是冒泡成原始异常', () async {
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'T',
        client: MockClient((_) async => throw http.ClientException('boom')),
      );

      await expectLater(
        api.listDevices(),
        throwsA(isA<CloudException>().having((e) => e.error.code, 'code', ErrorCode.transport)),
      );
    });
  });

  group('命令转发', () {
    test('设备拒绝命令（400 + 合法响应体）要原样交给调用方', () async {
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'T',
        client: MockClient(
          (_) async => _res({
              'ok': false,
              'error': {'code': 'busy', 'message': '设备正在标定'},
            }, 400),
        ),
      );

      // 不抛异常 —— 这是设备的业务回复，不是传输失败
      final j = await api.rawCommand('d1', {'cmd': 'calibrate_co2'});

      expect(j['ok'], isFalse);
      expect((j['error'] as Map)['code'], 'busy');
    });

    test('真正的传输失败仍然抛 CloudException', () async {
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'T',
        client: MockClient((_) async => throw http.ClientException('down')),
      );

      await expectLater(
        api.rawCommand('d1', {'cmd': 'get_config'}),
        throwsA(isA<CloudException>()),
      );
    });
  });

  group('历史', () {
    test('区间参数走 query，缺失指标保持 null 而不是 0', () async {
      final rec = _Recorder();
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'T',
        client: rec.client(
          (_) => {
            'points': [
              {'bucket_at': 1000, 'presence_s': 60, 'co2_avg': 812.5},
            ],
            'truncated': true,
            'retention_floor': 900,
          },
        ),
      );

      final r = await api.history('d1', from: 100, to: 200);

      expect(rec.last!.url.queryParameters, {'from': '100', 'to': '200'});
      expect(r.points.single.co2Avg, 812.5);
      // 该桶没有噪音数据 —— 必须是 null，不能补 0，否则曲线会假装有个安静时段
      expect(r.points.single.noiseAvg, isNull);
      expect(r.truncated, isTrue);
      expect(r.retentionFloor, 900);
    });

    test('空结果不炸', () async {
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'T',
        client: MockClient((_) async => _res(<String, Object?>{})),
      );

      final r = await api.history('d1', from: 0, to: 1);

      expect(r.points, isEmpty);
      expect(r.truncated, isFalse);
    });
  });
}
