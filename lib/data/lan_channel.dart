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

import '../core/api_error.dart';
import '../core/contracts/command.dart';
import '../core/contracts/history.dart';
import '../core/contracts/telemetry.dart';
import '../core/lan_reachability.dart';
import 'device_channel.dart';

class LanChannel implements DeviceChannel {
  LanChannel({
    required this.host,
    required this.token,
    this.port = 80,
    http.Client? httpClient,
    this.connectWebSocket = WebSocketChannel.connect,
    this.reachability = lanReachability,
  }) : _http = httpClient ?? http.Client();

  final String host;
  final int port;

  /// 配网时生成的配对 Token。局域网不等于可信网络，内网也必须鉴权。
  final String token;

  final http.Client _http;

  /// 注入以便单测替换掉真实连接。
  final WebSocketChannel Function(Uri) connectWebSocket;

  /// 可达性判定。注入以便在测试里模拟 https 网页版的环境
  /// —— 真跑一个 https 页面来测这条分支代价太大。
  final LanReachability Function(String host) reachability;

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

  /// 订阅地址。token 走查询串 —— **浏览器的 WebSocket API 不允许设置请求头**，
  /// web 构建没有别的办法把凭证带上去（与云通道 S-12 撞的是同一堵墙）。
  ///
  /// 设备端两种都认，所以原生构建其实可以走请求头；这里统一用查询串，
  /// 免得两个平台跑在不同的代码路径上 —— 那样 web 上的 bug 在原生上复现不出来。
  Uri _wsUri(String path) => Uri(
    scheme: 'ws',
    host: host,
    port: port,
    path: path,
    queryParameters: token.isEmpty ? null : {'token': token},
  );

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

    // 浏览器会拦掉 https 页面发往 http 的请求（混合内容，见 S-14）。
    // 不先判的话，用户看到的是「连接不上设备：XMLHttpRequest error」，
    // 于是去查 Token、IP、防火墙 —— 而那些都没问题，这条路本身不通。
    //
    // 也不重连：重试一万次结果都一样，只会把日志刷满、把电池耗光。
    if (reachability(host).isBlocked) {
      _emitStatus(ChannelState.failed, lanBlockedTitle);
      return;
    }

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

  /// 设备自己存的最近三小时（契约 §9.1 的 `GET /api/v1/history`）。
  ///
  /// 局域网模式下这是**唯一**的历史来源 —— 云关掉之后，
  /// 没有它历史页就是一片空白。
  ///
  /// 设备给的是按列的序列（每个指标一个数组），这里转成 App 统一用的
  /// 按点结构。转换放在这一层而不是让 UI 认两种形状：
  /// UI 认两种形状，就意味着每加一个图表都要写两遍。
  Future<HistoryResult> history({required int fromS}) async {
    final res = await _http
        .get(_uri('/api/v1/history'), headers: _headers)
        .timeout(const Duration(seconds: 10));

    if (res.statusCode != 200) {
      throw CloudException(
        CommandError(
          res.statusCode == 401 ? ErrorCode.unauthorized : ErrorCode.transport,
          '取历史失败（HTTP ${res.statusCode}）',
        ),
      );
    }

    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (body is! Map) {
      throw const CloudException(CommandError(ErrorCode.internal, '历史响应格式非法'));
    }
    final j = body.cast<String, Object?>();

    final startAt = (j['start_at'] as num?)?.toInt() ?? 0;
    final bucketS = (j['bucket_s'] as num?)?.toInt() ?? 60;
    final series = (j['series'] as Map?)?.cast<String, Object?>() ?? const {};

    List<double?> col(String key) {
      final raw = series[key];
      if (raw is! List) return const [];
      // null 要原样保留 —— 设备用它表示「这一分钟没有有效读数」。
      // 折成 0 会在曲线上画出一条假谷底。
      return raw.map((v) => v is num ? v.toDouble() : null).toList();
    }

    final co2 = col('co2');
    final temperature = col('temperature');
    final humidity = col('humidity');
    final noise = col('noise');
    final lux = col('lux');
    final presence = col('presence_s');

    final count = (j['count'] as num?)?.toInt() ?? co2.length;
    double? at(List<double?> c, int i) => i < c.length ? c[i] : null;

    final points = <HistoryPoint>[
      for (var i = 0; i < count; i++)
        HistoryPoint(
          bucketAt: startAt + i * bucketS,
          presenceS: (at(presence, i) ?? 0).round(),
          co2Avg: at(co2, i),
          // 设备不存分钟内峰值 —— 省 RAM，而三小时的曲线看趋势不看毛刺
          co2Max: null,
          temperatureAvg: at(temperature, i),
          humidityAvg: at(humidity, i),
          noiseAvg: at(noise, i),
          luxAvg: at(lux, i),
        ),
    ];

    // 设备只存三小时。用户选了更长的跨度时如实说被截断了 ——
    // 直接给三小时的数据而不吭声，用户会以为更早那段真的没事发生。
    final truncated = startAt > 0 && fromS < startAt;

    return HistoryResult(
      points: points,
      truncated: truncated,
      retentionFloor: startAt,
    );
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
