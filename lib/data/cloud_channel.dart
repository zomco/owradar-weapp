/// 云通道：REST + WSS 接 mmradar-server。
///
/// 与 [LanChannel] 实现同一个 [DeviceChannel] 接口 —— UI 完全感知不到差别。
/// 帧格式与局域网一致（契约 §9.3 刻意如此），因此解析逻辑可以共用。
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/contracts/command.dart';
import '../core/contracts/telemetry.dart';
import 'cloud_api.dart';
import 'device_channel.dart';

class CloudChannel implements DeviceChannel {
  CloudChannel({
    required this.api,
    required this.deviceId,
    this.connectWebSocket = WebSocketChannel.connect,
  });

  final CloudApi api;
  final String deviceId;
  final WebSocketChannel Function(Uri, {Iterable<String>? protocols}) connectWebSocket;

  @override
  ChannelKind get kind => ChannelKind.cloud;

  final _telemetry = StreamController<Telemetry>.broadcast();
  final _alerts = StreamController<Alert>.broadcast();
  final _status = StreamController<ChannelStatus>.broadcast();

  WebSocketChannel? _ws;
  StreamSubscription<Object?>? _wsSub;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _disposed = false;
  Telemetry? _latest;

  @override
  Stream<Telemetry> get telemetry => _telemetry.stream;
  @override
  Stream<Alert> get alerts => _alerts.stream;
  @override
  Stream<ChannelStatus> get status => _status.stream;
  @override
  Telemetry? get latest => _latest;

  void _emit(ChannelState s, [String detail = '']) {
    if (!_status.isClosed) _status.add(ChannelStatus(kind, s, detail: detail));
  }

  /// 把 http(s) 的 baseUrl 换成 ws(s)，并带上一次性票据。
  ///
  /// 这里放的是票据而不是 access token：**浏览器的 WebSocket API 不允许
  /// 设置请求头**，凭证只能进查询串，而 URL 会进日志、历史与 Referer。
  /// 票据只能订阅这一台设备、30 秒有效、用一次即废。
  Uri _streamUri(String ticket) {
    final base = Uri.parse(api.baseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/v1/devices/$deviceId/stream',
      queryParameters: {'ticket': ticket},
    );
  }

  @override
  Future<void> connect() async {
    if (_disposed) return;
    _emit(ChannelState.connecting);

    // 先取一次快照：WS 握手可能慢，用户希望立刻看到数据；
    // 顺便把 token 是否有效验证掉 —— WS 的失败原因往往看不清。
    try {
      final online = await api.isOnline(deviceId);
      if (!online) {
        _emit(ChannelState.connecting, '设备当前离线，等待上线');
      }
    } on CloudException catch (e) {
      if (e.error.code == ErrorCode.unauthorized) {
        // 登录态失效，重连没有意义 —— 交给上层去刷新 token
        _emit(ChannelState.failed, '登录已过期，请重新登录');
        return;
      }
      _emit(ChannelState.failed, e.error.display);
      _scheduleReconnect();
      return;
    }

    await _openSocket();
  }

  Future<void> _openSocket() async {
    if (_disposed) return;

    // 票据是一次性的：每次握手（含每次重连）都得重新换一张
    final String ticket;
    try {
      ticket = await api.streamTicket(deviceId);
    } on CloudException catch (e) {
      if (e.error.code == ErrorCode.unauthorized) {
        _emit(ChannelState.failed, '登录已过期，请重新登录');
        return;
      }
      _emit(ChannelState.failed, e.error.display);
      _scheduleReconnect();
      return;
    }
    if (_disposed) return;

    try {
      final ws = connectWebSocket(_streamUri(ticket));
      _ws = ws;
      _wsSub = ws.stream.listen(
        _onFrame,
        onDone: () {
          _emit(ChannelState.reconnecting, '连接已断开');
          _scheduleReconnect();
        },
        onError: (Object e) {
          _emit(ChannelState.reconnecting, '$e');
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
      _reconnectAttempt = 0;
      _emit(ChannelState.connected);
    } on Object catch (e) {
      _emit(ChannelState.failed, '$e');
      _scheduleReconnect();
    }
  }

  /// 指数退避，上限 30 秒。移动网络切换、设备重启都会断连，
  /// 无脑快速重试只会烧电池和流量。
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
      return;
    }

    final payload = env['payload'];
    if (payload is! Map) return;
    final body = payload.cast<String, Object?>();

    switch (env['type']) {
      case 'snapshot':
        final t = Telemetry.fromJson(body);
        _latest = t;
        if (!_telemetry.isClosed) _telemetry.add(t);
      case 'delta':
        final base = _latest;
        // 云端的 DeviceDO 已经把 delta 合进内存快照才扇出，
        // 正常不会收到裸 delta；收到就说明服务端行为变了，按合并处理兜底。
        if (base == null) return;
        final merged = base.mergeDelta(body);
        _latest = merged;
        if (!_telemetry.isClosed) _telemetry.add(merged);
      case 'alert':
        final a = Alert.tryParse(body);
        if (a != null && !_alerts.isClosed) _alerts.add(a);
      case 'event':
        // 设备上下线通知
        final online = body['online'];
        if (online == false) _emit(ChannelState.connected, '设备已离线');
    }
  }

  @override
  Future<CommandResult> send(CommandRequest request) async {
    // 走 REST：请求/响应配对天然清晰，且 WS 断线时命令仍然可用。
    // 服务端会转给 DeviceDO，由它按 req_id 等设备的响应。
    try {
      final res = await _postCommand(request);
      return res;
    } on CloudException catch (e) {
      return CommandFailed(e.error);
    }
  }

  Future<CommandResult> _postCommand(CommandRequest request) async {
    final j = await api.rawCommand(deviceId, request.toJson());
    return CommandResult.fromJson(j);
  }

  @override
  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    await _wsSub?.cancel();
    await _ws?.sink.close();
    _ws = null;
    _emit(ChannelState.idle);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await disconnect();
    await _telemetry.close();
    await _alerts.close();
    await _status.close();
  }
}
