/// 会话与连接模式。
///
/// 连接模式是本产品的一个明确承诺：
/// **用户可以完全关掉云，设备仍是功能完整的本地监测仪**（见 00-product-spec.md US-5）。
/// 因此模式是一等公民，而不是藏在角落的开关。
library;

import 'package:shared_preferences/shared_preferences.dart';

enum ConnectMode {
  /// 只连局域网。隐私最好，无历史、无远程推送。
  lanOnly,

  /// 只连云。不在同一网段时用。
  cloudOnly;

  String get label => switch (this) {
    ConnectMode.lanOnly => '仅局域网',
    ConnectMode.cloudOnly => '云端',
  };

  String get description => switch (this) {
    ConnectMode.lanOnly => '数据不出局域网。没有历史曲线和远程推送。',
    ConnectMode.cloudOnly => '可远程查看、保存历史、推送告警。',
  };
}

class Session {
  const Session({
    required this.mode,
    this.accessToken,
    this.refreshToken,
    this.email,
    this.deviceId,
    this.cloudBaseUrl = 'http://127.0.0.1:8787',
  });

  final ConnectMode mode;
  final String? accessToken;
  final String? refreshToken;
  final String? email;

  /// 云模式下当前选中的设备。
  final String? deviceId;
  final String cloudBaseUrl;

  bool get isLoggedIn => accessToken != null && accessToken!.isNotEmpty;

  /// 云模式可用的前提：已登录且选了设备。
  bool get cloudReady => mode == ConnectMode.cloudOnly && isLoggedIn && deviceId != null;

  Session copyWith({
    ConnectMode? mode,
    String? accessToken,
    String? refreshToken,
    String? email,
    String? deviceId,
    String? cloudBaseUrl,
    bool clearAuth = false,
    bool clearDevice = false,
  }) => Session(
    mode: mode ?? this.mode,
    accessToken: clearAuth ? null : (accessToken ?? this.accessToken),
    refreshToken: clearAuth ? null : (refreshToken ?? this.refreshToken),
    email: clearAuth ? null : (email ?? this.email),
    deviceId: clearDevice ? null : (deviceId ?? this.deviceId),
    cloudBaseUrl: cloudBaseUrl ?? this.cloudBaseUrl,
  );
}

/// 会话持久化。
///
/// 用 SharedPreferences 而不是安全存储：web 上没有 Keychain 等价物，
/// 而 refresh token 的泄露风险由服务端的短有效期与轮换来兜底。
/// 原生构建上线前应换成 flutter_secure_storage —— 见 README「尚未实现」。
class SessionStore {
  static const _kMode = 'connect_mode';
  static const _kAccess = 'access_token';
  static const _kRefresh = 'refresh_token';
  static const _kEmail = 'email';
  static const _kDeviceId = 'cloud_device_id';
  static const _kCloudUrl = 'cloud_base_url';

  Future<Session> load() async {
    final p = await SharedPreferences.getInstance();
    return Session(
      mode: p.getString(_kMode) == ConnectMode.cloudOnly.name
          ? ConnectMode.cloudOnly
          : ConnectMode.lanOnly,
      accessToken: p.getString(_kAccess),
      refreshToken: p.getString(_kRefresh),
      email: p.getString(_kEmail),
      deviceId: p.getString(_kDeviceId),
      cloudBaseUrl: p.getString(_kCloudUrl) ?? 'http://127.0.0.1:8787',
    );
  }

  Future<void> save(Session s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMode, s.mode.name);
    await p.setString(_kCloudUrl, s.cloudBaseUrl);

    await _put(p, _kAccess, s.accessToken);
    await _put(p, _kRefresh, s.refreshToken);
    await _put(p, _kEmail, s.email);
    await _put(p, _kDeviceId, s.deviceId);
  }

  Future<void> _put(SharedPreferences p, String key, String? value) =>
      value == null ? p.remove(key) : p.setString(key, value);
}
