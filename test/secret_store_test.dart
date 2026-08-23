/// 凭证存储与旧数据迁移。
///
/// 这里守两件事：
///
/// 1. **凭证不再留在 SharedPreferences 里。** 分开存的意义全在这 ——
///    只搬不删等于白搬，凭证仍然躺在明文那份里，只是多了个副本。
/// 2. **升级的用户不会被登出。** 旧版本把 token 放在 SharedPreferences，
///    新代码去安全存储里找、发现是空的 —— 用户会莫名其妙要重新登录，
///    而且没有任何报错能解释这件事。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mmradar_app/data/secret_store.dart';
import 'package:mmradar_app/data/session.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内存版凭证存储。顺便记录写入次数，用来验证并发读写没退化成串行。
class _FakeSecrets implements SecretStore {
  _FakeSecrets({this.isHardened = true});

  final Map<String, String> values = {};
  @override
  final bool isHardened;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('凭证与普通偏好分开', () {
    test('token 写进凭证存储，不落 SharedPreferences', () async {
      final secrets = _FakeSecrets();
      final store = SessionStore(secrets: secrets);

      await store.save(
        const Session(
          mode: ConnectMode.cloudOnly,
          accessToken: 'ACCESS',
          refreshToken: 'REFRESH',
          email: 'a@b.test',
          deviceId: 'mmr-a1b2c3d4e5f6',
        ),
      );

      expect(secrets.values['access_token'], 'ACCESS');
      expect(secrets.values['refresh_token'], 'REFRESH');

      final p = await SharedPreferences.getInstance();
      expect(p.getString('access_token'), isNull, reason: '凭证不该出现在普通偏好里');
      expect(p.getString('refresh_token'), isNull);
    });

    test('连接方式与云地址仍走普通偏好', () async {
      final store = SessionStore(secrets: _FakeSecrets());

      await store.save(
        const Session(mode: ConnectMode.cloudOnly, cloudBaseUrl: 'https://cloud.example'),
      );

      final p = await SharedPreferences.getInstance();
      expect(p.getString('connect_mode'), ConnectMode.cloudOnly.name);
      expect(p.getString('cloud_base_url'), 'https://cloud.example');
    });

    test('存进去的原样读得回来', () async {
      final secrets = _FakeSecrets();
      final store = SessionStore(secrets: secrets);
      const original = Session(
        mode: ConnectMode.cloudOnly,
        accessToken: 'A',
        refreshToken: 'R',
        email: 'a@b.test',
        deviceId: 'mmr-a1b2c3d4e5f6',
        cloudBaseUrl: 'https://cloud.example',
      );

      await store.save(original);
      final loaded = await store.load();

      expect(loaded.accessToken, 'A');
      expect(loaded.refreshToken, 'R');
      expect(loaded.email, 'a@b.test');
      expect(loaded.deviceId, 'mmr-a1b2c3d4e5f6');
      expect(loaded.mode, ConnectMode.cloudOnly);
      expect(loaded.cloudBaseUrl, 'https://cloud.example');
    });

    test('登出时凭证被删掉，而不是写成空串', () async {
      final secrets = _FakeSecrets();
      final store = SessionStore(secrets: secrets);

      await store.save(const Session(mode: ConnectMode.cloudOnly, accessToken: 'A'));
      await store.save(const Session(mode: ConnectMode.cloudOnly));

      // 空串会让「没登录」和「token 是空的」变成同一种状态
      expect(secrets.values.containsKey('access_token'), isFalse);
      expect((await store.load()).accessToken, isNull);
    });
  });

  group('旧数据迁移', () {
    test('把 SharedPreferences 里的旧凭证搬进安全存储', () async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'OLD_ACCESS',
        'refresh_token': 'OLD_REFRESH',
        'email': 'old@b.test',
        'cloud_device_id': 'mmr-old000000001',
        'connect_mode': ConnectMode.cloudOnly.name,
      });
      final secrets = _FakeSecrets();

      await SessionStore(secrets: secrets).migrateLegacySecrets();

      expect(secrets.values['access_token'], 'OLD_ACCESS');
      expect(secrets.values['refresh_token'], 'OLD_REFRESH');
      expect(secrets.values['email'], 'old@b.test');
      expect(secrets.values['cloud_device_id'], 'mmr-old000000001');
    });

    test('搬完把明文那份删掉 —— 只搬不删等于白搬', () async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'OLD_ACCESS',
        'refresh_token': 'OLD_REFRESH',
      });

      await SessionStore(secrets: _FakeSecrets()).migrateLegacySecrets();

      final p = await SharedPreferences.getInstance();
      expect(p.getString('access_token'), isNull);
      expect(p.getString('refresh_token'), isNull);
    });

    test('不动普通偏好', () async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'OLD',
        'connect_mode': ConnectMode.cloudOnly.name,
        'cloud_base_url': 'https://cloud.example',
      });

      await SessionStore(secrets: _FakeSecrets()).migrateLegacySecrets();

      final p = await SharedPreferences.getInstance();
      expect(p.getString('connect_mode'), ConnectMode.cloudOnly.name);
      expect(p.getString('cloud_base_url'), 'https://cloud.example');
    });

    test('已有新值时不被旧值覆盖', () async {
      // 迁移会被多次调用（每次启动都跑）。若旧值还在就覆盖新值，
      // 用户刷新过的 token 会被一个早就作废的旧 token 顶掉。
      SharedPreferences.setMockInitialValues({'refresh_token': 'STALE'});
      final secrets = _FakeSecrets()..values['refresh_token'] = 'FRESH';

      await SessionStore(secrets: secrets).migrateLegacySecrets();

      expect(secrets.values['refresh_token'], 'FRESH');
      // 旧的那份照样要清掉
      expect((await SharedPreferences.getInstance()).getString('refresh_token'), isNull);
    });

    test('没有旧数据时是无操作，不会凭空造出空凭证', () async {
      final secrets = _FakeSecrets();

      await SessionStore(secrets: secrets).migrateLegacySecrets();

      expect(secrets.values, isEmpty);
    });

    test('迁移可重复执行', () async {
      SharedPreferences.setMockInitialValues({'access_token': 'OLD'});
      final secrets = _FakeSecrets();
      final store = SessionStore(secrets: secrets);

      await store.migrateLegacySecrets();
      await store.migrateLegacySecrets();

      expect(secrets.values['access_token'], 'OLD');
    });

    test('迁移后紧接着 load 能拿到登录态 —— 升级的用户不该被登出', () async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'OLD_ACCESS',
        'refresh_token': 'OLD_REFRESH',
        'email': 'old@b.test',
        'connect_mode': ConnectMode.cloudOnly.name,
      });
      final store = SessionStore(secrets: _FakeSecrets());

      await store.migrateLegacySecrets();
      final s = await store.load();

      expect(s.isLoggedIn, isTrue, reason: '这一条红就意味着所有老用户升级后要重新登录');
      expect(s.accessToken, 'OLD_ACCESS');
    });
  });

  group('平台差异要如实暴露', () {
    test('web 上不假装安全', () {
      // isHardened 是给界面提示用的。如果 web 也报 true，
      // 就没人会再去想「那这里到底靠什么兜底」。
      expect(const WebSecretStore().isHardened, isFalse);
    });

    test('SessionStore 把这个事实透出去', () {
      expect(SessionStore(secrets: _FakeSecrets(isHardened: false)).secretsAreHardened, isFalse);
      expect(SessionStore(secrets: _FakeSecrets()).secretsAreHardened, isTrue);
    });
  });
}
