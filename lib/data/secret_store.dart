/// 凭证存储。
///
/// 与普通偏好（连接方式、云地址）分开的理由很简单：**它们的泄露后果不同**。
/// 连接方式被人看到无所谓，refresh token 被看到等于账号被接管 30 天。
/// 混在一个 SharedPreferences 里，就没有任何机制阻止下一个人往里
/// 再塞一个凭证。
///
/// 平台差异是真实存在的，**不粉饰**：
///
/// - **原生**（Android / iOS）：Keystore / Keychain，操作系统级保护，
///   别的应用读不到，root / 越狱之外拿不走。
/// - **Web**：**没有等价物**。localStorage 里的东西，同源的任何脚本都能读。
///   `flutter_secure_storage` 的 web 实现是拿 WebCrypto 加密后存 localStorage，
///   而密钥就在旁边 —— 那是混淆，不是加密，挡不住 XSS。
///   所以 web 上不假装安全，见 [WebSecretStore] 的注释。
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 存取凭证。实现按平台选，见 [createSecretStore]。
abstract class SecretStore {
  Future<String?> read(String key);

  /// value 为 null 时删除该键，而不是写一个空串 ——
  /// 空串会让「没登录」和「token 是空的」变成同一种状态。
  Future<void> write(String key, String? value);

  /// 这个实现是否真的由操作系统保护。
  ///
  /// 界面据此决定要不要提醒用户，**不是给代码分支用的** ——
  /// 分支一多就会有人写出「不安全就跳过保存」这种把 web 用户
  /// 每次刷新都踢下线的逻辑。
  bool get isHardened;
}

/// 原生：交给 Keystore / Keychain。
class NativeSecretStore implements SecretStore {
  const NativeSecretStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String? value) =>
      value == null ? _storage.delete(key: key) : _storage.write(key: key, value: value);

  @override
  bool get isHardened => true;
}

/// Web：localStorage，**不加密**。
///
/// 刻意不用 flutter_secure_storage 的 web 实现：它加密后把密钥
/// 存在同一个 localStorage 里，看起来更安全而实际不是。
/// 用一个明摆着不安全的实现，好过一个假装安全的 ——
/// 后者会让人以为这里已经处理好了，从而不去做真正有用的缓解。
///
/// 真正的缓解在服务端：access token 15 分钟过期，refresh token 一次一换。
/// 被盗的 refresh token 一旦被正主用过就作废，异常可被发现。
class WebSecretStore implements SecretStore {
  const WebSecretStore();

  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String key, String? value) async {
    final p = await SharedPreferences.getInstance();
    if (value == null) {
      await p.remove(key);
    } else {
      await p.setString(key, value);
    }
  }

  @override
  bool get isHardened => false;
}

/// 按平台挑一个实现。
SecretStore createSecretStore() => kIsWeb
    ? const WebSecretStore()
    : const NativeSecretStore(
        FlutterSecureStorage(
          // Android 不传 aOptions：v11 的默认已经是 Keystore 包裹的
          // AES-GCM（旧版那个 encryptedSharedPreferences 开关已被移除）。
          //
          // iOS 显式选 first_unlock：设备开机后解锁过一次才可读。
          // 默认的 unlocked 会让锁屏时读不到 —— 而后台刷新 token
          // 恰恰常发生在锁屏状态下，那会导致用户回来时已被登出。
          iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
        ),
      );
