/// 局域网端点的持久化。
///
/// 此前**完全没有持久化** —— `EndpointNotifier.build()` 直接返回模拟器地址，
/// 用户在设置里填好 IP 与配对码、点「保存并重连」、界面提示「已重新连接」，
/// 然后重启 App 就全没了。提示说的是真话（这次运行确实重连了），
/// 但用户理解的「保存」是另一个意思。
///
/// 与会话一样，**凭证与普通偏好分开存**：配对码走 [SecretStore]
/// （原生上是 Keystore / Keychain），地址与端口走 SharedPreferences。
/// 理由见 secret_store.dart —— 分开不只是为了那点保护，
/// 更是为了让「哪些东西是凭证」在代码里有个明确的位置。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'providers.dart' show DeviceEndpoint;
import 'secret_store.dart';

class EndpointStore {
  EndpointStore({SecretStore? secrets}) : _secrets = secrets ?? createSecretStore();

  final SecretStore _secrets;

  static const _kHost = 'lan_host';
  static const _kPort = 'lan_port';
  static const _kName = 'lan_name';

  /// 凭证侧。
  static const _kToken = 'lan_pairing_token';

  /// 读回上次保存的端点。没保存过时返回 null ——
  /// **不返回默认值**：由调用方决定「没配过」该显示什么，
  /// 这里替它决定的话，「用户填过 127.0.0.1」和「用户没填过」就分不开了。
  Future<DeviceEndpoint?> load() async {
    final p = await SharedPreferences.getInstance();
    final host = p.getString(_kHost);
    if (host == null || host.isEmpty) return null;

    return DeviceEndpoint(
      host: host,
      port: p.getInt(_kPort) ?? 80,
      token: await _secrets.read(_kToken) ?? '',
      name: p.getString(_kName) ?? '桌面助理',
    );
  }

  Future<void> save(DeviceEndpoint e) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kHost, e.host);
    await p.setInt(_kPort, e.port);
    await p.setString(_kName, e.name);
    // 空 token 要删而不是存空串 —— 空串会让「没配对」和「配对码是空的」
    // 变成同一种状态，而前者应当回到未配对的界面。
    await _secrets.write(_kToken, e.token.isEmpty ? null : e.token);
  }

  /// 清掉已保存的端点。用户换设备时用。
  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kHost);
    await p.remove(_kPort);
    await p.remove(_kName);
    await _secrets.write(_kToken, null);
  }
}
