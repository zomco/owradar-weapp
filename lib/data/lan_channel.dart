/// 局域网通道：HTTP + WebSocket 直连设备。
///
/// 这条路径的意义是**没有云也能用** —— 隐私敏感用户可以完全关掉云连接，
/// 设备仍是一个功能完整的桌面环境监测仪。延迟也比经云更低。
///
/// 见契约 §9.1。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/contracts/command.dart';
import '../core/contracts/telemetry.dart';
import 'device_channel.dart';

class LanChannel implements DeviceChannel {
  LanChannel({
    required this.host,
    required this.token,
    this.port = 80,
    http.Client? httpClient,
    this.connectWebSocket = WebSocketChannel.connect,
  }) : _http = httpClient ?? http.Client();

  final String host;
  final int port;

  /// 配网时生成的配对 Token。局域网不等于可信网络，内网也必须鉴权。
  final String token;

  final http.Client _http;

  /// 注入以便单测替换掉真实连接。
  final WebSocketChannel Function(Uri) connectWebSocket;

  @override
  ChannelKind get kind => ChannelKind.lan;

  final _telemetry = StreamController<Telemetry>.broadcast();
  final _alerts = StreamController<Alert>.broadcast();
  final _status = StreamController<ChannelStatus>.broadcast();

  WebSocketChannel? _ws;
  StreamSubscription<Object?>? _wsSub;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _disposed = false;

  Telemetry? _latest;

  /// 已下发但未收到响应的命令。设备用 req_id 关联。
  final _pending = <String, Completer<CommandResult>>{};

  @override
  Stream<Telemetry> get telemetry => _telemetry.stream;
  @override
  Stream<Alert> get alerts => _alerts.stream;
  @override
  Stream<ChannelStatus> get status => _status.stream;
  @override
  Telemetry? get latest => _latest;

  Uri _uri(String path) => Uri(scheme: 'http', host: host, port: port, path: path);
  Uri _wsUri(String path) => Uri(scheme: 'ws', host: host, port: port, path: path);

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (token.isNotEmpty) 'Authorization': 'Bearer $token',
  };

  void _emitStatus(ChannelState s, [String detail = '']) {
    if (!_status.isClosed) _status.add(ChannelStatus(kind, s, detail: detail));
  }

  @override
  Future<void> connect() async {
    if (_disposed) return;
    _emitStatus(ChannelState.connecting);

    // 先用 HTTP 取一次快照：WebSocket 握手可能慢，但用户希望立刻看到数据。
    // 顺便验证 host 与 token 是否正确 —— WS 的失败原因往往看不清楚。
    try {
      final res = await _http
          .get(_uri('/api/v1/snapshot'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 401) {
        _emitStatus(ChannelState.failed, '配对 Token 无效');
        return;
      }
      if (res.statusCode == 200) {
        _ingestSnapshot(jsonDecode(res.body) as Map<String, Object?>);
      }
    } on Object catch (e) {
      _emitStatus(ChannelState.failed, '连接不上设备：$e');
      _scheduleReconnect();
      return;
    }

    _openSocket();
  }

  void _openSocket() {
    if (_disposed) return;
    try {
      final ws = connectWebSocket(_wsUri('/api/v1/stream'));
      _ws = ws;
      _wsSub = ws.stream.listen(
        _onFrame,
        onDone: () {
          _emitStatus(ChannelState.reconnecting, '连接已断开');
          _scheduleReconnect();
        },
        onError: (Object e) {
          _emitStatus(ChannelState.reconnecting, '$e');
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
      _reconnectAttempt = 0;
      _emitStatus(ChannelState.connected);
    } on Object catch (e) {
      _emitStatus(ChannelState.failed, '$e');
      _scheduleReconnect();
    }
  }

  /// 指数退避重连，上限 30 秒。
  /// 设备重启、路由器换频段都会断连，无脑快速重试只会烧电池。
  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectAttempt = (_reconnectAttempt + 1).clamp(1, 6);
    final delay = Duration(seconds: [1, 2, 4, 8, 15, 30][_reconnectAttempt - 1]);
    _reconnectTimer = Timer(delay, connect);
  }

  void _onFrame(Object? raw) {
    if (raw is! String) return;
    Map<String, Object?> env;
    try {
      env = jsonDecode(raw) as Map<String, Object?>;
    } on Object {
      return; // 坏帧丢弃，不值得断开连接
    }

    final payload = env['payload'];
    if (payload is! Map) return;
    final body = payload.cast<String, Object?>();

    switch (env['type']) {
      case 'snapshot':
        _ingestSnapshot(body);
      case 'delta':
        _ingestDelta(body);
      case 'alert':
        final a = Alert.tryParse(body);
        if (a != null && !_alerts.isClosed) _alerts.add(a);
      case 'response':
        _resolvePending(body);
    }
  }

  void _ingestSnapshot(Map<String, Object?> body) {
    final t = Telemetry.fromJson(body);
    _latest = t;
    if (!_telemetry.isClosed) _telemetry.add(t);
  }

  void _ingestDelta(Map<String, Object?> body) {
    final base = _latest;
    if (base == null) {
      // 还没有基线就收到增量：无法正确合并，直接请全量。
      unawaited(getSnapshot());
      return;
    }

    final incoming = (body['seq'] as num?)?.toInt();
    // seq 不连续说明丢包，重新对齐而不是拿一份残缺的状态糊弄 UI。
    if (incoming != null && incoming != base.seq + 1) {
      unawaited(getSnapshot());
      return;
    }

    final merged = base.mergeDelta(body);
    _latest = merged;
    if (!_telemetry.isClosed) _telemetry.add(merged);
  }

  void _resolvePending(Map<String, Object?> body) {
    final reqId = body['req_id'];
    if (reqId is! String) return;
    final c = _pending.remove(reqId);
    if (c != null && !c.isCompleted) c.complete(CommandResult.fromJson(body));
  }

  @override
  Future<CommandResult> send(CommandRequest request) async {
    // 走 HTTP 而不是 WS：HTTP 的请求/响应配对是天然的，
    // 而且 WS 断线时命令仍然可用。
    try {
      final res = await _http
          .post(_uri('/api/v1/command'), headers: _headers, body: jsonEncode(request.toJson()))
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 401) {
        return const CommandFailed(CommandError(ErrorCode.unauthorized));
      }
      final body = jsonDecode(res.body);
      if (body is! Map) {
        return const CommandFailed(CommandError(ErrorCode.internal, '响应格式非法'));
      }
      return CommandResult.fromJson(body.cast<String, Object?>());
    } on TimeoutException {
      return const CommandFailed(CommandError(ErrorCode.busy, '设备未在超时内响应'));
    } on Object catch (e) {
      return CommandFailed(CommandError(ErrorCode.transport, '$e'));
    }
  }

  @override
  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    await _wsSub?.cancel();
    await _ws?.sink.close();
    _ws = null;
    _emitStatus(ChannelState.idle);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    _http.close();
    await _telemetry.close();
    await _alerts.close();
    await _status.close();
  }
}
