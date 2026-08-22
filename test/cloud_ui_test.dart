/// 云相关界面：设备列表、历史曲线、设置。
///
/// 重点不是「像不像」，而是**不会骗人**：
/// 没数据要说没数据，被保留期裁掉要说清楚，
/// 局域网模式下不能假装有历史。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mmradar_app/data/cloud_api.dart';
import 'package:mmradar_app/data/providers.dart';
import 'package:mmradar_app/data/session.dart';
import 'package:mmradar_app/features/devices/devices_page.dart';
import 'package:mmradar_app/features/history/history_page.dart';
import 'package:mmradar_app/features/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个不会真的发请求的 CloudApi，仅用于让界面认为「云可用」。
CloudApi _stubApi() => CloudApi(
  baseUrl: 'http://stub',
  accessToken: 'T',
  client: MockClient((_) async => http.Response('{}', 200)),
);

int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Riverpod 3 没有公开导出 Override 类型，所以 helper 直接收整个
/// ProviderScope，而不是收一个 overrides 列表。
Future<void> _pump(WidgetTester tester, ProviderScope scope) async {
  await tester.pumpWidget(scope);
  // 多帧：FutureProvider 的成功与失败落在不同的微任务轮次上，
  // 只 pump 两帧的话错误态还没到，测试会误报「没渲染错误信息」。
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('设备列表', () {
    testWidgets('在线与离线要能一眼分辨', (tester) async {
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            cloudApiProvider.overrideWithValue(_stubApi()),
            cloudDevicesProvider.overrideWith(
              (ref) async => [
                CloudDevice(id: 'd1', name: '书房', lastSeenAt: _now - 30),
                CloudDevice(id: 'd2', name: '工位', lastSeenAt: _now - 7200),
              ],
            ),
          ],
          child: const MaterialApp(home: DevicesPage()),
        ),
      );

      expect(find.text('书房'), findsOneWidget);
      expect(find.textContaining('在线'), findsOneWidget);
      expect(find.textContaining('2 小时前'), findsOneWidget);
    });

    testWidgets('从未上线的设备不能显示成刚刚在线', (tester) async {
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            cloudApiProvider.overrideWithValue(_stubApi()),
            cloudDevicesProvider.overrideWith(
              (ref) async => [const CloudDevice(id: 'd3', name: '新设备')],
            ),
          ],
          child: const MaterialApp(home: DevicesPage()),
        ),
      );

      expect(find.textContaining('从未上线'), findsOneWidget);
    });

    testWidgets('空列表要解释「设备不联网也能用」', (tester) async {
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            cloudApiProvider.overrideWithValue(_stubApi()),
            cloudDevicesProvider.overrideWith((ref) async => <CloudDevice>[]),
          ],
          child: const MaterialApp(home: DevicesPage()),
        ),
      );

      expect(find.text('还没有绑定设备'), findsOneWidget);
      expect(find.textContaining('不联网也能用'), findsOneWidget);
    });

    testWidgets('拉取失败给重试', (tester) async {
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            cloudApiProvider.overrideWithValue(_stubApi()),
            cloudDevicesProvider.overrideWith((ref) async => throw Exception('连不上服务端')),
          ],
          child: const MaterialApp(home: DevicesPage()),
        ),
      );

      expect(find.textContaining('连不上服务端'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('添加设备要说清配对码从哪来', (tester) async {
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            cloudApiProvider.overrideWithValue(_stubApi()),
            cloudDevicesProvider.overrideWith((ref) async => <CloudDevice>[]),
          ],
          child: const MaterialApp(home: DevicesPage()),
        ),
      );

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.textContaining('屏幕会显示 8 位配对码'), findsOneWidget);
    });
  });

  group('历史', () {
    const points = [
      HistoryPoint(bucketAt: 1700000000, presenceS: 60, co2Avg: 800),
      HistoryPoint(bucketAt: 1700000060, presenceS: 60, co2Avg: 1000),
      HistoryPoint(bucketAt: 1700000120, presenceS: 30, co2Avg: 1200),
    ];

    testWidgets('局域网模式明说没有历史，而不是显示空图', (tester) async {
      // cloudApiProvider 默认为 null（未登录 / 仅局域网）
      await _pump(tester, const ProviderScope(child: MaterialApp(home: HistoryPage())));

      expect(find.text('历史数据需要连接云端'), findsOneWidget);
      expect(find.textContaining('设备本身不保存历史'), findsOneWidget);
      expect(find.text('区间统计'), findsNothing);
    });

    testWidgets('有数据时给出区间统计', (tester) async {
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            cloudApiProvider.overrideWithValue(_stubApi()),
            historyProvider.overrideWith(
              (ref) async =>
                  const HistoryResult(points: points, truncated: false, retentionFloor: 0),
            ),
          ],
          child: const MaterialApp(home: HistoryPage()),
        ),
      );

      expect(find.text('区间统计'), findsOneWidget);
      // 平均 (800+1000+1200)/3 = 1000
      expect(find.text('1000 ppm'), findsOneWidget);
      expect(find.text('1200 ppm'), findsOneWidget);
      expect(find.text('800 ppm'), findsOneWidget);
      // 60+60+30 = 150s → 2 分钟
      expect(find.text('2 分钟'), findsOneWidget);
    });

    testWidgets('被保留期裁剪时必须告诉用户，否则会以为那段没数据', (tester) async {
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            cloudApiProvider.overrideWithValue(_stubApi()),
            historyProvider.overrideWith(
              (ref) async =>
                  const HistoryResult(points: points, truncated: true, retentionFloor: 1699000000),
            ),
          ],
          child: const MaterialApp(home: HistoryPage()),
        ),
      );

      expect(find.textContaining('保留 7 天'), findsOneWidget);
    });

    testWidgets('空区间说清是设备没跑，不是界面坏了', (tester) async {
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            cloudApiProvider.overrideWithValue(_stubApi()),
            historyProvider.overrideWith(
              (ref) async => const HistoryResult(points: [], truncated: false, retentionFloor: 0),
            ),
          ],
          child: const MaterialApp(home: HistoryPage()),
        ),
      );

      expect(find.textContaining('设备离线或还没运行这么久'), findsOneWidget);
    });

    testWidgets('切换时间跨度会改写查询条件', (tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            cloudApiProvider.overrideWithValue(_stubApi()),
            historyProvider.overrideWith(
              (ref) async =>
                  const HistoryResult(points: points, truncated: false, retentionFloor: 0),
            ),
          ],
          child: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return const MaterialApp(home: HistoryPage());
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(container.read(historySpanProvider), 3600);

      await tester.tap(find.text('24 小时'));
      await tester.pumpAndSettle();

      expect(container.read(historySpanProvider), 24 * 3600);
    });
  });

  group('设置', () {
    testWidgets('默认仅局域网，且解释了取舍', (tester) async {
      await _pump(tester, const ProviderScope(child: MaterialApp(home: SettingsPage())));

      expect(find.text('仅局域网'), findsOneWidget);
      expect(find.textContaining('数据不出局域网'), findsOneWidget);
      expect(find.text('设备地址'), findsOneWidget);
    });

    testWidgets('局域网也要填配对 Token —— 内网不等于可以裸奔', (tester) async {
      await _pump(tester, const ProviderScope(child: MaterialApp(home: SettingsPage())));

      expect(find.textContaining('内网也需要鉴权'), findsOneWidget);
    });

    testWidgets('切到云端且未登录时引导登录', (tester) async {
      await _pump(
        tester,
        ProviderScope(
          overrides: [sessionProvider.overrideWith(_FixedSession.new)],
          child: const MaterialApp(home: SettingsPage()),
        ),
      );

      expect(find.text('登录'), findsOneWidget);
      expect(find.textContaining('远程查看设备'), findsOneWidget);
      // 未登录不该出现设备入口
      expect(find.text('我的设备'), findsNothing);
    });

    testWidgets('已登录时显示账号与设备入口', (tester) async {
      await _pump(
        tester,
        ProviderScope(
          overrides: [
            sessionProvider.overrideWith(_LoggedInSession.new),
            cloudApiProvider.overrideWithValue(_stubApi()),
            cloudDevicesProvider.overrideWith(
              (ref) async => [CloudDevice(id: 'd1', name: '书房', lastSeenAt: _now)],
            ),
          ],
          child: const MaterialApp(home: SettingsPage()),
        ),
      );

      expect(find.text('a@b.c'), findsOneWidget);
      expect(find.text('我的设备'), findsOneWidget);
      expect(find.text('书房'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
    });
  });
}

/// 云模式但未登录。
class _FixedSession extends SessionNotifier {
  @override
  Session build() => const Session(mode: ConnectMode.cloudOnly);
}

/// 云模式且已登录、已选设备。
class _LoggedInSession extends SessionNotifier {
  @override
  Session build() => const Session(
    mode: ConnectMode.cloudOnly,
    accessToken: 'T',
    refreshToken: 'R',
    email: 'a@b.c',
    deviceId: 'd1',
  );
}
