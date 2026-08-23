/// mmradar-server 的 REST 客户端。
///
/// 只管 HTTP 与 token；实时数据走 [CloudChannel] 的 WebSocket。
/// 接口定义见 mmradar-server/README.md §4。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/api_error.dart';
import '../core/contracts/command.dart';
import '../core/contracts/history.dart';
import '../core/contracts/rule.dart';

// 历史模型与错误类型现在住在 core/，但既有调用方都从这里 import ——
// 转出去，免得为一次搬家把十几处 import 全改一遍。
export '../core/api_error.dart';
export '../core/contracts/history.dart';

/// 账号信息与日报偏好。
class AccountInfo {
  const AccountInfo({
    required this.email,
    required this.plan,
    required this.dailyReportAllowed,
    required this.reportEnabled,
    required this.weeklyReportEnabled,
    required this.tzOffsetMin,
    required this.reportHour,
  });

  final String email;
  final String plan;

  /// 当前套餐是否包含日报。
  ///
  /// 由服务端的配额算出来，**客户端不自己判断 plan == 'pro'** ——
  /// 那样改定价要同时改四端。
  final bool dailyReportAllowed;

  final bool reportEnabled;

  /// 周报开关。与日报**分开**：两者回答不同的问题
  /// （昨天怎么样 / 这周比上周如何），绑一起的话想关周报的用户
  /// 只能连日报一起关掉。
  ///
  /// 与日报共用同一个配额位与发送时刻 —— 没有单独的「周报配额」。
  final bool weeklyReportEnabled;

  /// UTC 偏移（分钟）。用分钟不是小时：尼泊尔 +345、印度 +330。
  final int tzOffsetMin;

  /// 本地发送时刻，0-23。
  final int reportHour;

  factory AccountInfo.fromJson(Map<String, Object?> j) {
    final quota = (j['quota'] as Map?)?.cast<String, Object?>() ?? const {};
    final report = (j['report'] as Map?)?.cast<String, Object?>() ?? const {};
    return AccountInfo(
      email: j['email'] as String? ?? '',
      plan: j['plan'] as String? ?? 'free',
      dailyReportAllowed: quota['daily_report'] as bool? ?? false,
      reportEnabled: report['enabled'] as bool? ?? false,
      weeklyReportEnabled: report['weekly_enabled'] as bool? ?? false,
      tzOffsetMin: (report['tz_offset_min'] as num?)?.toInt() ?? 0,
      reportHour: (report['hour'] as num?)?.toInt() ?? 8,
    );
  }
}

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

class AuthTokens {
  const AuthTokens({required this.access, required this.refresh, required this.expiresIn});

  final String access;
  final String refresh;
  final int expiresIn;
}


class CloudApi {
  CloudApi({
    required this.baseUrl,
    http.Client? client,
    this.accessToken,
    this.refreshToken,
    this.onTokensRefreshed,
    this.onSessionExpired,
  }) : _http = client ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  /// 访问令牌。刷新会话后由外部直接改写 —— 不重建 CloudApi，
  /// 免得把正在进行的请求和它持有的 http.Client 一起丢掉。
  String? accessToken;

  /// 刷新令牌。access token 只有 15 分钟，没有它用户每刷一次界面就要重新登录。
  String? refreshToken;

  /// 刷新成功后回调，把新的一对令牌交给上层持久化。
  ///
  /// **必须存下来**：服务端每次刷新都发新的 refresh token，
  /// 虽然旧的目前还有效，但不该依赖这个实现细节。
  final void Function(AuthTokens tokens)? onTokensRefreshed;

  /// 刷新失败（refresh token 也过期或无效）时回调。
  /// 上层应当据此清掉会话并把用户送回登录页。
  final void Function()? onSessionExpired;

  /// 正在进行的刷新。
  ///
  /// 单飞：界面上多个 Provider 会同时发请求，token 一过期就是一片 401。
  /// 不合并的话会同时打出 N 个刷新请求，而且它们的结果互相覆盖，
  /// 最后存下哪一对是随机的。
  Future<bool>? _refreshing;

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

  /// 刷新一次令牌。并发调用共享同一次网络请求。
  ///
  /// 成功返回 true 并已把新的 accessToken 装好；失败返回 false 并通知上层。
  Future<bool> _refresh() {
    // 已经有人在刷了就等它，不再发一次
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;

    final token = refreshToken;
    if (token == null || token.isEmpty) {
      onSessionExpired?.call();
      return Future.value(false);
    }

    final future = () async {
      try {
        final tokens = await refreshSession(token);
        refreshToken = tokens.refresh;
        onTokensRefreshed?.call(tokens);
        return true;
      } on CloudException {
        // refresh token 也不行了 —— 重试没有意义，让用户重新登录
        onSessionExpired?.call();
        return false;
      } finally {
        _refreshing = null;
      }
    }();

    _refreshing = future;
    return future;
  }

  /// 执行一次请求；遇到 401 就刷新令牌并**只重试一次**。
  ///
  /// 只重试一次是关键：刷新完还 401 说明问题不在令牌上
  /// （比如访问了别人的设备），再试下去就是死循环。
  Future<Map<String, Object?>> _withAuthRetry(
    Future<Map<String, Object?>> Function() op,
  ) async {
    try {
      return await op();
    } on CloudException catch (e) {
      if (e.error.code != ErrorCode.unauthorized) rethrow;
      if (!await _refresh()) rethrow;
      return op();
    }
  }

  Future<Map<String, Object?>> _rawGet(String path, [Map<String, String>? query]) async {
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

  Future<Map<String, Object?>> _get(String path, [Map<String, String>? query]) =>
      _withAuthRetry(() => _rawGet(path, query));

  Future<Map<String, Object?>> _send(
    String method,
    String path,
    Object? body, {
    bool auth = true,
  }) {
    // auth=false 的只有登录与刷新本身。它们不能走重试包装 ——
    // 刷新接口自己返回 401 时再去刷新就是无限递归。
    if (!auth) return _rawSend(method, path, body, auth: false);
    return _withAuthRetry(() => _rawSend(method, path, body, auth: true));
  }

  Future<Map<String, Object?>> _rawSend(
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

  // ── 账号偏好 ────────────────────────────────────────────

  Future<AccountInfo> account() async {
    return AccountInfo.fromJson(await _get('/v1/me'));
  }

  /// 更新日报偏好。只传要改的项 —— 服务端做的是部分更新。
  Future<AccountInfo> updateReportPrefs({
    bool? enabled,
    bool? weeklyEnabled,
    int? tzOffsetMin,
    int? hour,
  }) async {
    final body = <String, Object?>{
      'report_enabled': ?enabled,
      'weekly_report_enabled': ?weeklyEnabled,
      'tz_offset_min': ?tzOffsetMin,
      'report_hour': ?hour,
    };
    if (body.isEmpty) {
      throw const CloudException(CommandError(ErrorCode.invalidParam, '没有要更新的项'));
    }
    // PATCH 只回 report 段，其余字段从这次请求里拿不到 ——
    // 重新拉一次完整账号，免得界面上的套餐信息变成空的
    await _send('PATCH', '/v1/me', body);
    return account();
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
  Future<Map<String, Object?>> rawCommand(String deviceId, Map<String, Object?> command) =>
      _withAuthRetry(() => _rawCommand(deviceId, command));

  Future<Map<String, Object?>> _rawCommand(
    String deviceId,
    Map<String, Object?> command,
  ) async {
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
