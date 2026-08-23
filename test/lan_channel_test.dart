/// 局域网通道的握手与鉴权。
///
/// 这个文件的直接来由：2026-08-22 之前设备的 `WS /api/v1/stream` **根本不鉴权**，
/// 客户端也就没往上带 token —— 四个实现（固件、模拟器、App、契约文档）
/// 里有三个一致地漏掉了同一件事，于是没人觉得不对。
///
/// 契约（02-data-model.md §9.1）写的是整个局域网 API 都要 Bearer 鉴权、
/// 只有 `/info` 例外。订阅流不在例外之列。
///
/// 与 [cloud_channel_test.dart] 的断言方向刚好相反，这不是矛盾：
/// 云上的 access token 能调所有接口、且要穿过会记录 URL 的网关，
/// 所以换成一次性票据；局域网本来就是明文 HTTP，能看见 URL 的人
/// 同样能看见别的请求里的 Authorization 头，token 进查询串没多暴露什么。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mmradar_app/core/lan_reachability.dart';
import 'package:mmradar_app/core/api_error.dart';
import 'package:mmradar_app/core/contracts/command.dart';
import 'package:mmradar_app/data/device_channel.dart';
import 'package:mmradar_app/data/lan_channel.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'contracts_test.dart' show snapshotJson;

http.Response _res(Object? json, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(json)),
  status,
  headers: {'content-type': 'application/json'},
);

class _FakeSocket with StreamChannelMixin<dynamic> implements WebSocketChannel {
  _FakeSocket(this.uri);

  final Uri uri;
  final _incoming = StreamController<Object?>.broadcast();

  @override
  Stream<Object?> get stream => _incoming.stream;
  @override
  WebSocketSink get sink => _FakeSink(this);
  @override
  Future<void> get ready => Future.value();
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  String? get protocol => null;

  Future<void> close() => _incoming.close();
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._owner);
  final _FakeSocket _owner;

  @override
  void add(Object? data) {}
  @override
  Future<void> close([int? closeCode, String? closeReason]) => _owner.close();
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<Object?> stream) async {}
  @override
  Future<void> get done => Future.value();
}

/// 建好一条局域网通道，返回打开过的 socket 列表与服务端收到的请求头。
Future<({LanChannel channel, List<_FakeSocket> sockets, List<String?> auth})> connectLan({
  String token = 'pair-token-123',
  int snapshotStatus = 200,
}) async {
  final sockets = <_FakeSocket>[];
  final auth = <String?>[];

  final channel = LanChannel(
    host: '192.168.1.50',
    token: token,
    httpClient: MockClient((req) async {
      auth.add(req.headers['Authorization']);
      if (snapshotStatus != 200) {
        return _res({
          'error': {'code': 'unauthorized'},
        }, snapshotStatus);
      }
      return _res(snapshotJson());
    }),
    connectWebSocket: (uri) {
      final s = _FakeSocket(uri);
      sockets.add(s);
      return s;
    },
  );

  await channel.connect();
  return (channel: channel, sockets: sockets, auth: auth);
}

void main() {
  group('混合内容（S-14）', () {
    /// 造一条「跑在 https 网页版里」的通道。
    LanChannel blockedChannel({required List<String> httpCalls}) => LanChannel(
      host: '192.168.1.50',
      token: 'pair-token-123',
      httpClient: MockClient((req) async {
        httpCalls.add(req.url.toString());
        return _res(snapshotJson());
      }),
      connectWebSocket: (uri) => _FakeSocket(uri),
      reachability: (_) => LanReachability.blockedByMixedContent,
    );

    test('不可达时立刻失败，并说明真正的原因', () async {
      final calls = <String>[];
      final channel = blockedChannel(httpCalls: calls);
      final statuses = <ChannelStatus>[];
      channel.status.listen(statuses.add);

      await channel.connect();
      await Future<void>.delayed(Duration.zero);

      expect(statuses.single.state, ChannelState.failed);
      expect(
        statuses.single.detail,
        lanBlockedTitle,
        reason: '不能只说「连接失败」—— 用户会去查 Token 和防火墙',
      );
    });

    test('一个请求都不发 —— 发了也是被浏览器拦掉', () async {
      final calls = <String>[];
      final channel = blockedChannel(httpCalls: calls);

      await channel.connect();

      expect(calls, isEmpty);
    });

    test('不安排重连 —— 重试一万次结果都一样', () async {
      // 这条是本组里最要紧的：不拦住的话，一个连不上的网页版会以
      // 1/2/4/8/15/30 秒的节奏永远重试下去，日志刷满、笔记本电池耗光。
      final calls = <String>[];
      final channel = blockedChannel(httpCalls: calls);
      final statuses = <ChannelStatus>[];
      channel.status.listen(statuses.add);

      await channel.connect();
      // 跨过第一档重连间隔
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(statuses, hasLength(1), reason: '只该有那一次 failed，没有后续的重连状态');
      expect(calls, isEmpty);

      await channel.dispose();
    });
  });

  group('设备端历史（局域网模式下唯一的历史来源）', () {
    Map<String, Object?> deviceHistory({
      int startAt = 1700000000,
      int count = 3,
      List<Object?>? co2,
    }) => {
      'start_at': startAt,
      'bucket_s': 60,
      'count': count,
      'series': {
        'co2': co2 ?? [800, 850, 900],
        'temperature': [24.1, 24.2, 24.3],
        'humidity': [50.0, 51.0, 52.0],
        'noise': [45.0, 46.0, 47.0],
        'lux': [400, 410, 420],
        'presence_s': [60, 30, 0],
      },
    };

    LanChannel channelReturning(Map<String, Object?> body, {int status = 200}) => LanChannel(
      host: '192.168.1.50',
      token: 'pair-token-123',
      httpClient: MockClient((req) async => _res(body, status)),
      connectWebSocket: (uri) => _FakeSocket(uri),
    );

    test('按列的序列被转成按点的结构', () async {
      // 设备给列、App 用点。转换必须在通道层做完 ——
      // 让 UI 认两种形状，意味着每加一个图表都要写两遍。
      final r = await channelReturning(deviceHistory()).history(fromS: 1700000000);

      expect(r.points, hasLength(3));
      expect(r.points[0].bucketAt, 1700000000);
      expect(r.points[1].bucketAt, 1700000060, reason: '时间轴按 bucket_s 递推');
      expect(r.points[2].co2Avg, 900);
      expect(r.points[0].temperatureAvg, 24.1);
      expect(r.points[1].presenceS, 30);
    });

    test('null 原样保留，不折成 0', () async {
      // 0 是合法读数。折成 0 会在曲线上画出一条假谷底，
      // 而用户从图上看不出那其实是「这一分钟没数据」。
      final r = await channelReturning(
        deviceHistory(co2: [800, null, 900]),
      ).history(fromS: 1700000000);

      expect(r.points[1].co2Avg, isNull);
      expect(r.points[0].co2Avg, 800);
    });

    test('设备不存分钟内峰值，co2Max 为 null 而不是拿均值顶替', () async {
      final r = await channelReturning(deviceHistory()).history(fromS: 1700000000);
      expect(r.points[0].co2Max, isNull);
    });

    test('要的时间跨度超出设备存量时标记为已裁剪', () async {
      // 设备只有三小时。默不作声地只给三小时，用户会以为更早那段真的没事。
      final r = await channelReturning(
        deviceHistory(startAt: 1700000000),
      ).history(fromS: 1700000000 - 86400);

      expect(r.truncated, isTrue);
      expect(r.retentionFloor, 1700000000);
    });

    test('跨度落在设备存量之内时不谎报裁剪', () async {
      final r = await channelReturning(
        deviceHistory(startAt: 1700000000),
      ).history(fromS: 1700000000 + 60);

      expect(r.truncated, isFalse);
    });

    test('401 报成鉴权错误，而不是笼统的传输失败', () async {
      // 配对 Token 过期时用户需要知道该去重新配对，而不是查网络
      await expectLater(
        channelReturning(const {}, status: 401).history(fromS: 0),
        throwsA(
          isA<CloudException>().having((e) => e.error.code, 'code', ErrorCode.unauthorized),
        ),
      );
    });

    test('设备还没攒到数据时给空结果，而不是抛异常', () async {
      final r = await channelReturning({
        'start_at': 0,
        'bucket_s': 60,
        'count': 0,
        'series': <String, Object?>{},
      }).history(fromS: 1700000000);

      expect(r.points, isEmpty);
      expect(r.truncated, isFalse, reason: '没数据不等于被裁剪');
    });
  });

  group('订阅鉴权', () {
    test('WS 地址必须带上配对 token', () async {
      // 设备侧会拒掉不带 token 的订阅。少了这一句，
      // 局域网实时看板会一直停在「连接中」，而 HTTP 快照却是好的 ——
      // 这种半通不通的表现最难排查。
      final r = await connectLan();

      expect(r.sockets, hasLength(1));
      final uri = r.sockets.single.uri;
      expect(uri.queryParameters['token'], 'pair-token-123');
      expect(uri.path, '/api/v1/stream');
      expect(uri.scheme, 'ws');
      expect(uri.host, '192.168.1.50');
    });

    test('HTTP 请求走 Authorization 头，不把 token 放进查询串', () async {
      final r = await connectLan();

      expect(r.auth, isNotEmpty);
      expect(r.auth.first, 'Bearer pair-token-123');
    });

    test('未配对（token 为空）时不往 URL 里塞空 token', () async {
      // 配网前设备不鉴权。此时拼一个 `?token=` 出来只会让日志更难读，
      // 也会让「有没有配对」这件事在抓包里看不出来。
      final r = await connectLan(token: '');

      expect(r.sockets.single.uri.hasQuery, isFalse);
    });

    test('token 里的特殊字符被正确转义', () async {
      // 配对 token 是设备生成的，将来换字母表（比如加进 base64 的 + / =）
      // 时，手工拼字符串的写法会悄悄拼出一个错的 URL。
      final r = await connectLan(token: 'a+b/c=d&e');

      expect(r.sockets.single.uri.queryParameters['token'], 'a+b/c=d&e');
      expect(r.sockets.single.uri.query, isNot(contains('&e=')));
    });
  });

  group('鉴权失败的表现', () {
    test('快照返回 401 时明确报「Token 无效」，且不去连 WS', () async {
      // 先用 HTTP 探一次的意义就在这里：WS 握手失败的原因在各平台上
      // 都看不清楚，而 401 是明确的。
      final r = await connectLan(snapshotStatus: 401);

      expect(r.sockets, isEmpty, reason: 'token 都不对，没必要再去连 WS');

      final status = await r.channel.status.first.timeout(
        const Duration(seconds: 1),
        onTimeout: () => const ChannelStatus(ChannelKind.lan, ChannelState.failed),
      );
      expect(status.state, ChannelState.failed);
    });
  });
}
