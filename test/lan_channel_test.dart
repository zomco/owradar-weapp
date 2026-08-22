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
