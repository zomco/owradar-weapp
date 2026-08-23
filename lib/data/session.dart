/// 会话与连接模式。
///
/// 连接模式是本产品的一个明确承诺：
/// **用户可以完全关掉云，设备仍是功能完整的本地监测仪**（见 00-product-spec.md US-5）。
/// 因此模式是一等公民，而不是藏在角落的开关。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'secret_store.dart';

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
/// **凭证与普通偏好分开存**：token 走 [SecretStore]（原生上是
/// Keystore / Keychain），连接方式、云地址这些走 SharedPreferences。
///
/// 分开不只是为了原生上那点保护，更是为了让「哪些东西是凭证」
/// 在代码里有个明确的位置。混在一起的话，没有任何机制阻止
/// 下一个人往普通偏好里再塞一个 token。
///
/// 邮箱也归到凭证一侧：它本身不是密码，但配上 refresh token 就是
/// 一副完整的身份，而且它是登录用的标识符。
///
/// Web 上没有真正的安全存储，[SecretStore.isHardened] 会是 false ——
/// 那里的缓解手段在服务端（access token 15 分钟、refresh 一次一换），
/// 不在客户端。见 secret_store.dart。
class SessionStore {
  SessionStore({SecretStore? secrets}) : _secrets = secrets ?? createSecretStore();

  final SecretStore _secrets;

  static const _kMode = 'connect_mode';
  static const _kCloudUrl = 'cloud_base_url';

  // 凭证侧
  static const _kAccess = 'access_token';
  static const _kRefresh = 'refresh_token';
  static const _kEmail = 'email';
  static const _kDeviceId = 'cloud_device_id';

  /// 当前平台的凭证存储是否由操作系统保护。界面据此提示用户。
  bool get secretsAreHardened => _secrets.isHardened;

  Future<Session> load() async {
    final p = await SharedPreferences.getInstance();
    // 四个凭证并发读。原生的 Keychain 每次读都有开销，
    // 串行的话启动时要多等好几十毫秒。
    final values = await Future.wait([
      _secrets.read(_kAccess),
      _secrets.read(_kRefresh),
      _secrets.read(_kEmail),
      _secrets.read(_kDeviceId),
    ]);

    return Session(
      mode: p.getString(_kMode) == ConnectMode.cloudOnly.name
          ? ConnectMode.cloudOnly
          : ConnectMode.lanOnly,
      accessToken: values[0],
      refreshToken: values[1],
      email: values[2],
      deviceId: values[3],
      cloudBaseUrl: p.getString(_kCloudUrl) ?? 'http://127.0.0.1:8787',
    );
  }

  Future<void> save(Session s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMode, s.mode.name);
    await p.setString(_kCloudUrl, s.cloudBaseUrl);

    await Future.wait([
      _secrets.write(_kAccess, s.accessToken),
      _secrets.write(_kRefresh, s.refreshToken),
      _secrets.write(_kEmail, s.email),
      _secrets.write(_kDeviceId, s.deviceId),
    ]);
  }

  /// 把旧版本遗留在 SharedPreferences 里的凭证搬到 [SecretStore]。
  ///
  /// 不搬的话，升级上来的用户会**莫名其妙被登出一次** ——
  /// 新代码去安全存储里找，那里是空的。
  ///
  /// 搬完必须把明文那份删掉，否则这次迁移等于白做：
  /// 凭证仍然躺在 SharedPreferences 里，只是多了一份副本。
  Future<void> migrateLegacySecrets() async {
    final p = await SharedPreferences.getInstance();

    for (final key in [_kAccess, _kRefresh, _kEmail, _kDeviceId]) {
      final legacy = p.getString(key);
      if (legacy == null) continue;

      // 已经有新值就不覆盖：新值一定比遗留的那份新
      if (await _secrets.read(key) == null) {
        await _secrets.write(key, legacy);
      }
      await p.remove(key);
    }
  }
}
