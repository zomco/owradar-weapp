/// mmradar-server 的 REST 客户端。
///
/// 只管 HTTP 与 token；实时数据走 [CloudChannel] 的 WebSocket。
/// 接口定义见 mmradar-server/README.md §4。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/contracts/command.dart';
import '../core/contracts/rule.dart';

/// 云端返回的设备条目。
class CloudDevice {
  const CloudDevice({
    required this.id,
    required this.name,
    this.model = 'MMR-1',
    this.fwVersion,
    this.lastSeenAt,
  });

  final String id;
  final String name;
  final String model;
  final String? fwVersion;
  final int? lastSeenAt;

  /// 超过 5 分钟没消息就认为不在线。
  /// 服务端的 `/status` 更准，但列表页不值得为每台设备都打一次。
  bool get looksOnline {
    final t = lastSeenAt;
    if (t == null) return false;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 - t < 300;
  }

  factory CloudDevice.fromJson(Map<String, Object?> j) => CloudDevice(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '桌面助理',
    model: j['model'] as String? ?? 'MMR-1',
    fwVersion: j['fw_version'] as String?,
    lastSeenAt: (j['last_seen_at'] as num?)?.toInt(),
  );
}

/// 分钟级历史数据点。原始秒级数据不入库 —— 见服务端架构 §4。
class HistoryPoint {
  const HistoryPoint({
    required this.bucketAt,
    required this.presenceS,
    this.co2Avg,
    this.co2Max,
    this.temperatureAvg,
    this.humidityAvg,
    this.noiseAvg,
    this.luxAvg,
  });

  final int bucketAt;
  final int presenceS;
  final double? co2Avg;
  final double? co2Max;
  final double? temperatureAvg;
  final double? humidityAvg;
  final double? noiseAvg;
  final double? luxAvg;

  factory HistoryPoint.fromJson(Map<String, Object?> j) => HistoryPoint(
    bucketAt: (j['bucket_at'] as num?)?.toInt() ?? 0,
    presenceS: (j['presence_s'] as num?)?.toInt() ?? 0,
    co2Avg: (j['co2_avg'] as num?)?.toDouble(),
    co2Max: (j['co2_max'] as num?)?.toDouble(),
    temperatureAvg: (j['temperature_avg'] as num?)?.toDouble(),
    humidityAvg: (j['humidity_avg'] as num?)?.toDouble(),
    noiseAvg: (j['noise_avg'] as num?)?.toDouble(),
    luxAvg: (j['lux_avg'] as num?)?.toDouble(),
  );
}

class HistoryResult {
  const HistoryResult({
    required this.points,
    required this.truncated,
    required this.retentionFloor,
  });

  final List<HistoryPoint> points;

  /// true 表示请求区间超出了套餐的保留期，已被裁剪。
  /// 界面应当提示用户，而不是让他以为那段时间真的没数据。
  final bool truncated;
  final int retentionFloor;
}

class AuthTokens {
  const AuthTokens({required this.access, required this.refresh, required this.expiresIn});

  final String access;
  final String refresh;
  final int expiresIn;
}

/// 云端 API 调用失败。用 [CommandError] 复用同一套错误码与用户文案。
class CloudException implements Exception {
  const CloudException(this.error);
  final CommandError error;

  @override
  String toString() => error.display;
}

class CloudApi {
  CloudApi({required this.baseUrl, http.Client? client, this.accessToken})
    : _http = client ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  /// 访问令牌。刷新会话后由外部直接改写 —— 不重建 CloudApi，
  /// 免得把正在进行的请求和它持有的 http.Client 一起丢掉。
  String? accessToken;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Map<String, String> _headers({bool auth = true}) => {
    'Content-Type': 'application/json',
    if (auth && accessToken != null) 'Authorization': 'Bearer $accessToken',
  };

  /// 按 UTF-8 解码响应体。
  ///
  /// 不能用 `res.body` —— 服务端若没在 Content-Type 里写 charset，
  /// http 包会退回 latin-1（RFC 规定的默认值），中文错误信息会直接变成乱码
  /// 甚至抛「Contains invalid characters」。但 JSON 按 RFC 8259 就是 UTF-8，
  /// 所以这里不看 charset，直接按 UTF-8 解。
  static Object? _json(http.Response res) {
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on Object {
      return null;
    }
  }

  /// 统一的响应处理：把 HTTP 状态与服务端错误体翻译成 [CloudException]。
  Map<String, Object?> _decode(http.Response res) {
    final body = _json(res);

    if (res.statusCode >= 200 && res.statusCode < 300) {
      return body is Map ? body.cast<String, Object?>() : <String, Object?>{};
    }

    final err = body is Map ? body['error'] : null;
    if (err is Map) {
      throw CloudException(
        CommandError(ErrorCode.parse(err['code']), err['message'] as String? ?? ''),
      );
    }
    // 服务端没给结构化错误时按状态码兜底
    final code = switch (res.statusCode) {
      401 => ErrorCode.unauthorized,
      402 => ErrorCode.unsupported,
      404 => ErrorCode.notFound,
      _ => ErrorCode.internal,
    };
    throw CloudException(CommandError(code, 'HTTP ${res.statusCode}'));
  }

  Future<Map<String, Object?>> _get(String path, [Map<String, String>? query]) async {
    try {
      final res = await _http
          .get(_uri(path, query), headers: _headers())
          .timeout(const Duration(seconds: 15));
      return _decode(res);
    } on CloudException {
      rethrow;
    } on Object catch (e) {
      throw CloudException(CommandError(ErrorCode.transport, '$e'));
    }
  }

  Future<Map<String, Object?>> _send(
    String method,
    String path,
    Object? body, {
    bool auth = true,
  }) async {
    try {
      final req = http.Request(method, _uri(path))
        ..headers.addAll(_headers(auth: auth))
        ..body = body == null ? '' : jsonEncode(body);
      final streamed = await _http.send(req).timeout(const Duration(seconds: 15));
      return _decode(await http.Response.fromStream(streamed));
    } on CloudException {
      rethrow;
    } on Object catch (e) {
      throw CloudException(CommandError(ErrorCode.transport, '$e'));
    }
  }

  // ── 账号 ────────────────────────────────────────────────

  /// 请求邮箱验证码。
  /// 返回开发环境回显的验证码；生产环境为 null（走真实邮件）。
  Future<String?> requestOtp(String email) async {
    final j = await _send('POST', '/v1/auth/otp', {'email': email}, auth: false);
    return j['dev_code'] as String?;
  }

  Future<AuthTokens> verifyOtp(String email, String code) async {
    final j = await _send('POST', '/v1/auth/verify', {'email': email, 'code': code}, auth: false);
    final access = j['access_token'] as String?;
    final refresh = j['refresh_token'] as String?;
    if (access == null || refresh == null) {
      throw const CloudException(CommandError(ErrorCode.internal, '服务端未返回 token'));
    }
    accessToken = access;
    return AuthTokens(
      access: access,
      refresh: refresh,
      expiresIn: (j['expires_in'] as num?)?.toInt() ?? 900,
    );
  }

  Future<AuthTokens> refreshSession(String refreshToken) async {
    final j = await _send('POST', '/v1/auth/refresh', {'refresh_token': refreshToken}, auth: false);
    final access = j['access_token'] as String?;
    final refresh = j['refresh_token'] as String?;
    if (access == null || refresh == null) {
      throw const CloudException(CommandError(ErrorCode.unauthorized, '会话已失效'));
    }
    accessToken = access;
    return AuthTokens(
      access: access,
      refresh: refresh,
      expiresIn: (j['expires_in'] as num?)?.toInt() ?? 900,
    );
  }

  // ── 设备 ────────────────────────────────────────────────

  Future<List<CloudDevice>> listDevices() async {
    final j = await _get('/v1/devices');
    final list = j['devices'];
    if (list is! List) return const [];
    return list
        .whereType<Map<Object?, Object?>>()
        .map((d) => CloudDevice.fromJson(d.cast<String, Object?>()))
        .toList();
  }

  /// 用配对码绑定设备。配对码由设备屏幕或串口给出，一次性、10 分钟过期。
  Future<CloudDevice> pair(String code, {String? name}) async {
    final j = await _send('POST', '/v1/devices/pair', {
      'code': code.toUpperCase(),
      if (name != null && name.isNotEmpty) 'name': name,
    });
    final d = j['device'];
    if (d is! Map) {
      throw const CloudException(CommandError(ErrorCode.internal, '服务端未返回设备'));
    }
    return CloudDevice.fromJson(d.cast<String, Object?>());
  }

  Future<void> unpair(String deviceId) => _send('DELETE', '/v1/devices/$deviceId', null);

  Future<CloudDevice> rename(String deviceId, String name) async {
    final j = await _send('PATCH', '/v1/devices/$deviceId', {'name': name});
    final d = j['device'];
    return d is Map
        ? CloudDevice.fromJson(d.cast<String, Object?>())
        : CloudDevice(id: deviceId, name: name);
  }

  Future<bool> isOnline(String deviceId) async {
    final j = await _get('/v1/devices/$deviceId/status');
    return j['online'] as bool? ?? false;
  }

  /// 换一张实时流的订阅票据。
  ///
  /// 为什么不能直接用 access token 连 WS：**浏览器的 WebSocket API
  /// 不允许设置请求头**，凭证只能进查询串，而 URL 会被日志和 Referer 记下来。
  /// 票据绑定到一台设备、30 秒有效、用一次即废 —— 见服务端 README §4。
  ///
  /// 每次重连都要重新换 —— 票据是一次性的。
  Future<String> streamTicket(String deviceId) async {
    final j = await _send('POST', '/v1/devices/$deviceId/stream-ticket', null);
    final ticket = j['ticket'] as String?;
    if (ticket == null || ticket.isEmpty) {
      throw const CloudException(CommandError(ErrorCode.internal, '服务端未返回票据'));
    }
    return ticket;
  }

  // ── 规则 ────────────────────────────────────────────────

  Future<List<Rule>> listRules(String deviceId) async {
    final j = await _get('/v1/devices/$deviceId/rules');
    final list = j['rules'];
    if (list is! List) return const [];
    return list
        .whereType<Map<Object?, Object?>>()
        .map((r) => Rule.fromJson(r.cast<String, Object?>()))
        .toList();
  }

  /// 保存规则。服务端会**先下发给设备**，设备拒绝就不写库 ——
  /// 云端不该出现设备上没有的规则。
  Future<void> saveRule(String deviceId, Rule rule) =>
      _send('PUT', '/v1/devices/$deviceId/rules/${rule.id}', rule.toJson());

  Future<void> deleteRule(String deviceId, String ruleId) =>
      _send('DELETE', '/v1/devices/$deviceId/rules/$ruleId', null);

  // ── 命令 ────────────────────────────────────────────────

  /// 把命令转给设备。服务端交给 DeviceDO，由它按 req_id 等设备响应。
  ///
  /// 返回原始 JSON 而不是 CommandResult：解析交给 [CloudChannel]，
  /// 这样 REST 客户端不必依赖通道层的类型。
  Future<Map<String, Object?>> rawCommand(String deviceId, Map<String, Object?> command) async {
    try {
      final res = await _http
          .post(
            _uri('/v1/devices/$deviceId/command'),
            headers: _headers(),
            body: jsonEncode(command),
          )
          .timeout(const Duration(seconds: 20));

      final body = _json(res);
      // 设备拒绝命令时服务端回 400，但响应体是合法的 CommandResponse，
      // 应当原样交给调用方，而不是当成传输错误。
      if (body is Map && body.containsKey('ok')) return body.cast<String, Object?>();
      return _decode(res);
    } on CloudException {
      rethrow;
    } on Object catch (e) {
      throw CloudException(CommandError(ErrorCode.transport, '$e'));
    }
  }

  // ── 历史 ────────────────────────────────────────────────

  Future<HistoryResult> history(String deviceId, {required int from, required int to}) async {
    final j = await _get('/v1/telemetry/$deviceId/history', {'from': '$from', 'to': '$to'});
    final list = j['points'];
    return HistoryResult(
      points: list is List
          ? list
                .whereType<Map<Object?, Object?>>()
                .map((p) => HistoryPoint.fromJson(p.cast<String, Object?>()))
                .toList()
          : const [],
      truncated: j['truncated'] as bool? ?? false,
      retentionFloor: (j['retention_floor'] as num?)?.toInt() ?? 0,
    );
  }

  void close() => _http.close();
}
