/// 局域网端点的持久化。
///
/// 这个文件的由来：此前端点**完全没有持久化**。用户在设置里填好 IP
/// 与配对码、点「保存并重连」、界面提示「已重新连接」，然后重启 App
/// 就全没了。提示说的是真话（这次运行确实重连了），
/// 但用户理解的「保存」是另一个意思。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mmradar_app/data/endpoint_store.dart';
import 'package:mmradar_app/data/providers.dart';
import 'package:mmradar_app/data/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSecrets implements SecretStore {
  final Map<String, String> values = {};

  @override
  bool get isHardened => true;

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
  late _FakeSecrets secrets;
  late EndpointStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets = _FakeSecrets();
    store = EndpointStore(secrets: secrets);
  });

  group('存取', () {
    test('存进去的原样读得回来', () async {
      const e = DeviceEndpoint(
        host: '192.168.1.50',
        port: 8080,
        token: 'pair-abc',
        name: '书房',
      );

      await store.save(e);
      final back = await store.load();

      expect(back?.host, '192.168.1.50');
      expect(back?.port, 8080);
      expect(back?.token, 'pair-abc');
      expect(back?.name, '书房');
    });

    test('配对码进凭证存储，不落普通偏好', () async {
      await store.save(
        const DeviceEndpoint(host: '192.168.1.50', token: 'pair-abc'),
      );

      expect(secrets.values['lan_pairing_token'], 'pair-abc');

      final p = await SharedPreferences.getInstance();
      // 配对码能读走这台设备的全部数据，不该和「端口号」躺在一起
      expect(p.getString('lan_pairing_token'), isNull);
      expect(p.getString('lan_host'), '192.168.1.50');
    });

    test('从没保存过时返回 null，而不是一个默认值', () async {
      // 替调用方决定默认值的话，「用户填过 127.0.0.1」和「用户没填过」
      // 就分不开了 —— 而这两种情况该显示的东西不一样
      expect(await store.load(), isNull);
    });

    test('空配对码存成删除，不存空串', () async {
      await store.save(const DeviceEndpoint(host: '10.0.0.2', token: 'x'));
      await store.save(const DeviceEndpoint(host: '10.0.0.2', token: ''));

      // 空串会让「没配对」和「配对码是空的」变成同一种状态
      expect(secrets.values.containsKey('lan_pairing_token'), isFalse);
      expect((await store.load())?.token, '');
    });

    test('清除之后回到「没保存过」', () async {
      await store.save(const DeviceEndpoint(host: '10.0.0.2', token: 'x'));
      await store.clear();

      expect(await store.load(), isNull);
      expect(secrets.values, isEmpty);
    });

    test('端口缺失时给默认 80，而不是崩', () async {
      // 老版本可能只存过 host。读不到端口时得能继续跑。
      SharedPreferences.setMockInitialValues({'lan_host': '10.0.0.9'});
      expect((await EndpointStore(secrets: secrets).load())?.port, 80);
    });

    test('覆盖保存不会留下上一台设备的配对码', () async {
      await store.save(const DeviceEndpoint(host: '10.0.0.1', token: 'old'));
      await store.save(const DeviceEndpoint(host: '10.0.0.2', token: 'new'));

      final back = await store.load();
      expect(back?.host, '10.0.0.2');
      expect(back?.token, 'new');
    });
  });
}
