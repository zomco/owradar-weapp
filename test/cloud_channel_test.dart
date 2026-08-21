/// 云通道的握手与鉴权。
///
/// 这个文件存在的直接原因：2026-08-21 之前 `CloudChannel` 把 access token
/// 塞在 `?token=` 里，而服务端只读 `Authorization` 头 —— 握手一律 401，
/// 云模式的实时看板完全不可用，而单元测试一条都没红。
///
/// 教训是 **WS 的 URL 拼装本身就是契约**，必须被断言，
/// 不能只靠「跑起来看看」。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mmradar_app/core/contracts/telemetry.dart';
import 'package:mmradar_app/data/cloud_api.dart';
import 'package:mmradar_app/data/cloud_channel.dart';
import 'package:mmradar_app/data/device_channel.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'contracts_test.dart' show snapshotJson;

const _deviceId = 'mmr-a1b2c3d4e5f6';

http.Response _res(Object? json, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(json)),
  status,
  headers: {'content-type': 'application/json'},
);

/// 记录服务端收到的请求，并按路径给出应答。
class _Server {
  _Server({this.online = true, this.ticketStatus = 200});

  final bool online;
  final int ticketStatus;

  final paths = <String>[];
  int ticketsIssued = 0;

  http.Client get client => MockClient((req) async {
    paths.add('${req.method} ${req.url.path}');

    if (req.url.path.endsWith('/status')) {
      return _res({'device_id': _deviceId, 'online': online});
    }
    if (req.url.path.endsWith('/stream-ticket')) {
      if (ticketStatus != 200) {
        return _res({
          'error': {'code': 'unauthorized', 'message': '登录已过期'},
        }, ticketStatus);
      }
      ticketsIssued++;
      // 每张票都不同 —— 票据是一次性的
      return _res({'ticket': 'ticket-$ticketsIssued', 'expires_in': 30});
    }
    return _res(<String, Object?>{});
  });
}

/// 假的 WebSocket：只记录被请求的 URI，并允许测试往里推帧。
class _FakeSocket with StreamChannelMixin<dynamic> implements WebSocketChannel {
  _FakeSocket(this.uri);

  final Uri uri;
  final _incoming = StreamController<Object?>.broadcast();
  final sent = <Object?>[];

  void push(Object? frame) => _incoming.add(frame);

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
  void add(Object? data) => _owner.sent.add(data);
  @override
  Future<void> close([int? closeCode, String? closeReason]) => _owner.close();
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<Object?> stream) async {}
  @override
  Future<void> get done => Future.value();
}

/// 建好一条通道，返回它、服务端记录、以及打开过的 socket。
Future<({CloudChannel channel, _Server server, List<_FakeSocket> sockets})> connectChannel({
  bool online = true,
  int ticketStatus = 200,
}) async {
  final server = _Server(online: online, ticketStatus: ticketStatus);
  final sockets = <_FakeSocket>[];

  final channel = CloudChannel(
    api: CloudApi(baseUrl: 'https://cloud.example', accessToken: 'JWT', client: server.client),
    deviceId: _deviceId,
    connectWebSocket: (uri, {protocols}) {
      final s = _FakeSocket(uri);
      sockets.add(s);
      return s;
    },
  );

  await channel.connect();
  return (channel: channel, server: server, sockets: sockets);
}

void main() {
  group('握手鉴权', () {
    test('WS 用一次性票据，绝不把 access token 放进 URL', () async {
      final c = await connectChannel();
      addTearDown(c.channel.dispose);

      expect(c.sockets, hasLength(1));
      final uri = c.sockets.single.uri;

      expect(uri.queryParameters['ticket'], 'ticket-1');
      // 这条是回归断言：token 出现在 URL 里就是当初那个 bug
      expect(uri.queryParameters.containsKey('token'), isFalse);
      expect(uri.toString(), isNot(contains('JWT')));
    });

    test('票据在握手之前换取', () async {
      final c = await connectChannel();
      addTearDown(c.channel.dispose);

      expect(c.server.paths, contains('POST /v1/devices/$_deviceId/stream-ticket'));
      expect(c.server.ticketsIssued, 1);
    });

    test('https 走 wss，路径与服务端路由一致', () async {
      final c = await connectChannel();
      addTearDown(c.channel.dispose);

      final uri = c.sockets.single.uri;
      expect(uri.scheme, 'wss');
      expect(uri.host, 'cloud.example');
      expect(uri.path, '/v1/devices/$_deviceId/stream');
    });

    test('换票失败于登录过期时不重连 —— 重试也还是过期', () async {
      final c = await connectChannel(ticketStatus: 401);
      addTearDown(c.channel.dispose);

      // 没有开过 socket
      expect(c.sockets, isEmpty);

      final status = await c.channel.status.first.timeout(
        const Duration(milliseconds: 200),
        onTimeout: () => const ChannelStatus(ChannelKind.cloud, ChannelState.connecting),
      );
      expect(status.state, anyOf(ChannelState.failed, ChannelState.connecting));
    });

    test('设备离线也照样订阅 —— 设备上线后要能立刻推过来', () async {
      final c = await connectChannel(online: false);
      addTearDown(c.channel.dispose);

      expect(c.sockets, hasLength(1));
    });
  });

  group('帧处理', () {
    test('快照帧转成 Telemetry 并进流', () async {
      final c = await connectChannel();
      addTearDown(c.channel.dispose);

      final next = c.channel.telemetry.first;
      c.sockets.single.push(
        jsonEncode({'type': 'snapshot', 'payload': snapshotJson()}),
      );

      final t = await next.timeout(const Duration(seconds: 2));
      expect(t.deviceId, isNotEmpty);
      expect(t.riskLevel, isA<RiskLevel>());
      // latest 要同步更新，否则重建 Provider 会闪一下 loading
      expect(c.channel.latest, isNotNull);
    });

    test('垃圾帧不炸通道', () async {
      final c = await connectChannel();
      addTearDown(c.channel.dispose);

      final sock = c.sockets.single;
      sock.push('not json');
      sock.push('{"type":"snapshot"}'); // 缺 payload
      sock.push('{"type":"unknown","payload":{}}');
      sock.push(<int>[1, 2, 3]); // 二进制帧
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 通道还活着：正常帧仍然能进来
      final next = c.channel.telemetry.first;
      sock.push(jsonEncode({'type': 'snapshot', 'payload': snapshotJson()}));
      await expectLater(next.timeout(const Duration(seconds: 2)), completes);
    });
  });

  test('通道类型是 cloud —— UI 靠它区分连接方式的文案', () async {
    final c = await connectChannel();
    addTearDown(c.channel.dispose);
    expect(c.channel.kind, ChannelKind.cloud);
  });
}
