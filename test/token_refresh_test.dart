/// access token 过期后的自动刷新。
///
/// 没有它的话，用户开着界面一刻钟（access token 的有效期）
/// 就会看到满屏「未授权」，而唯一的自救办法是退出重登。
///
/// 这里的重点是**并发**：界面上多个 Provider 同时发请求，
/// token 一过期就是一片 401 同时到达。刷新必须合并成一次，
/// 否则会打出 N 个刷新请求，且它们的结果互相覆盖。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mmradar_app/core/contracts/command.dart';
import 'package:mmradar_app/data/cloud_api.dart';

http.Response _res(Object? json, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(json)),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response _unauthorized() => _res({
  'error': {'code': 'unauthorized', 'message': 'token 已过期'},
}, 401);

/// 一个会在 access token 过期后返回 401 的假服务端。
class _Server {
  _Server({this.refreshWorks = true, this.refreshDelay = Duration.zero});

  final bool refreshWorks;

  /// 刷新接口的人为延迟。用来制造「多个请求同时撞上刷新」的时序。
  final Duration refreshDelay;

  /// 服务端认可的 access token。
  String validAccess = 'ACCESS_2';

  /// 刷新接口发出的 access token。
  ///
  /// 与 validAccess 分开，是为了能造出「刷新成功了但新令牌照样不好使」
  /// 这种情形 —— 那说明问题不在令牌上，重试再多次也没用。
  String? issuedAccess;

  int refreshCalls = 0;
  final protectedCalls = <String>[];

  http.Client get client => MockClient((req) async {
    if (req.url.path == '/v1/auth/refresh') {
      refreshCalls++;
      if (refreshDelay > Duration.zero) await Future<void>.delayed(refreshDelay);
      if (!refreshWorks) {
        return _res({
          'error': {'code': 'unauthorized', 'message': '会话已失效'},
        }, 401);
      }
      return _res({
        'access_token': issuedAccess ?? validAccess,
        'refresh_token': 'REFRESH_2',
        'expires_in': 900,
      });
    }

    // 受保护接口：只认当前有效的 access token
    final auth = req.headers['Authorization'];
    protectedCalls.add(auth ?? '');
    if (auth != 'Bearer $validAccess') return _unauthorized();

    if (req.url.path == '/v1/devices') return _res({'devices': <Object?>[]});
    if (req.url.path.endsWith('/stream-ticket')) {
      return _res({'ticket': 'T' * 64, 'expires_in': 30});
    }
    if (req.url.path.endsWith('/command')) return _res({'ok': true});
    return _res(<String, Object?>{});
  });
}

void main() {
  group('自动刷新', () {
    test('过期后自动换新令牌并重试，调用方无感', () async {
      final server = _Server();
      AuthTokens? saved;

      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'ACCESS_1', // 已过期
        refreshToken: 'REFRESH_1',
        client: server.client,
        onTokensRefreshed: (t) => saved = t,
      );

      // 调用方拿到的是正常结果，完全不知道中间刷过一次
      final devices = await api.listDevices();

      expect(devices, isEmpty);
      expect(server.refreshCalls, 1);
      // 两次受保护调用：先用旧 token 撞 401，刷新后用新 token 重试
      expect(server.protectedCalls, ['Bearer ACCESS_1', 'Bearer ACCESS_2']);
      expect(api.accessToken, 'ACCESS_2');
      expect(saved?.refresh, 'REFRESH_2', reason: '轮换后的 refresh token 必须交给上层持久化');
    });

    test('并发的多个 401 只触发一次刷新', () async {
      // 这条是本文件存在的主要理由。界面上多个 Provider 同时发请求，
      // 不合并的话会同时打出 N 个刷新请求。
      final server = _Server(refreshDelay: const Duration(milliseconds: 50));
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'ACCESS_1',
        refreshToken: 'REFRESH_1',
        client: server.client,
      );

      await Future.wait([
        api.listDevices(),
        api.listDevices(),
        api.listDevices(),
        api.isOnline('mmr-a1b2c3d4e5f6'),
      ]);

      expect(server.refreshCalls, 1, reason: '四个并发请求只该刷新一次');
    });

    test('刷新令牌也失效时通知上层登出，且不再重试', () async {
      final server = _Server(refreshWorks: false);
      var expired = 0;

      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'ACCESS_1',
        refreshToken: 'REFRESH_STALE',
        client: server.client,
        onSessionExpired: () => expired++,
      );

      await expectLater(
        api.listDevices(),
        throwsA(
          isA<CloudException>().having((e) => e.error.code, 'code', ErrorCode.unauthorized),
        ),
      );
      expect(expired, 1, reason: '必须通知上层，否则用户会卡在一个永远报错的界面');
      expect(server.refreshCalls, 1, reason: '刷新失败后不该反复重试');
    });

    test('没有 refresh token 时直接判为过期，不发无意义的请求', () async {
      final server = _Server();
      var expired = 0;

      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'ACCESS_1',
        client: server.client, // refreshToken 为 null
        onSessionExpired: () => expired++,
      );

      await expectLater(api.listDevices(), throwsA(isA<CloudException>()));
      expect(server.refreshCalls, 0);
      expect(expired, 1);
    });

    test('刷新后仍然 401 就放弃，不进死循环', () async {
      // 服务端认可的 token 与刷新接口发出的不一致 ——
      // 模拟「问题不在令牌上」（比如访问了别人的设备）
      final server = _Server()..issuedAccess = 'STILL_WRONG';
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'ACCESS_1',
        refreshToken: 'REFRESH_1',
        client: server.client,
      );

      await expectLater(api.listDevices(), throwsA(isA<CloudException>()));
      expect(server.refreshCalls, 1, reason: '只刷一次');
      expect(server.protectedCalls.length, 2, reason: '只重试一次');
    });
  });

  group('不该被包进重试的路径', () {
    test('登录与刷新接口自身不触发刷新 —— 否则是无限递归', () async {
      final server = _Server(refreshWorks: false);
      final api = CloudApi(
        baseUrl: 'http://x',
        refreshToken: 'REFRESH_1',
        client: server.client,
      );

      await expectLater(api.refreshSession('REFRESH_1'), throwsA(isA<CloudException>()));
      // 只有调用方自己那一次，没有由重试包装再触发的
      expect(server.refreshCalls, 1);
    });
  });

  group('覆盖到全部受保护接口', () {
    test('命令转发也会自动刷新', () async {
      final server = _Server();
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'ACCESS_1',
        refreshToken: 'REFRESH_1',
        client: server.client,
      );

      final resp = await api.rawCommand('mmr-a1b2c3d4e5f6', {'cmd': 'get_config'});

      expect(resp['ok'], isTrue);
      expect(server.refreshCalls, 1);
    });

    test('换订阅票据也会自动刷新 —— 否则实时流会在 15 分钟后断掉', () async {
      final server = _Server();
      final api = CloudApi(
        baseUrl: 'http://x',
        accessToken: 'ACCESS_1',
        refreshToken: 'REFRESH_1',
        client: server.client,
      );

      final ticket = await api.streamTicket('mmr-a1b2c3d4e5f6');

      expect(ticket, hasLength(64));
      expect(server.refreshCalls, 1);
    });
  });
}
