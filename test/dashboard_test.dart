/// 看板的 widget 测试。
///
/// 无头渲染整棵组件树并断言**实际显示出来的文字**。
/// 比截图更严格：截图要人眼判断，这里是机器断言。
///
/// 重点覆盖各 health 状态的渲染 —— 用户必须能一眼分辨
/// 「传感器坏了」和「数值正常」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmradar_app/core/contracts/telemetry.dart';
import 'package:mmradar_app/data/device_channel.dart';
import 'package:mmradar_app/data/providers.dart';
import 'package:mmradar_app/features/dashboard/dashboard_page.dart';

import 'contracts_test.dart' show snapshotJson;
import 'fake_channel.dart';

Future<FakeChannel> pumpDashboard(WidgetTester tester, Telemetry initial) async {
  final fake = FakeChannel(initial: initial);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [channelProvider.overrideWithValue(fake)],
      child: const MaterialApp(home: DashboardPage()),
    ),
  );
  await tester.pump();
  return fake;
}

void main() {
  testWidgets('在座时显示风险等级与建议', (tester) async {
    final t = Telemetry.fromJson(snapshotJson(riskLevel: 'poor', drivers: ['co2']));
    await pumpDashboard(tester, t);

    expect(find.text('较差'), findsOneWidget);
    expect(find.text('空气浑浊 · 建议开窗通风'), findsOneWidget);
    expect(find.text('在座'), findsOneWidget);
    expect(find.text('已在座 1 小时 2 分'), findsOneWidget);
    expect(find.text('68 cm'), findsOneWidget);
  });

  testWidgets('五项读数都渲染，单位正确', (tester) async {
    await pumpDashboard(tester, Telemetry.fromJson(snapshotJson()));

    expect(find.text('二氧化碳'), findsOneWidget);
    expect(find.text('900 ppm'), findsOneWidget);
    expect(find.text('24.9 °C'), findsOneWidget); // 只有温度带小数
    expect(find.text('50 %'), findsOneWidget);
    expect(find.text('48 dBA'), findsOneWidget);
  });

  testWidgets('传感器故障显示「故障」而不是陈旧值', (tester) async {
    // health=fault 但 value 仍有数 —— 继续显示它是最危险的做法
    final t = Telemetry.fromJson(
      snapshotJson(co2: {'value': 1320, 'unit': 'ppm', 'level': 'poor', 'health': 'fault'}),
    );
    await pumpDashboard(tester, t);

    expect(find.text('故障'), findsOneWidget);
    expect(find.text('1320 ppm'), findsNothing);
  });

  testWidgets('预热中显示状态与说明', (tester) async {
    final t = Telemetry.fromJson(
      snapshotJson(co2: {'value': null, 'unit': 'ppm', 'level': 'good', 'health': 'warming_up'}),
    );
    await pumpDashboard(tester, t);

    expect(find.text('预热中'), findsOneWidget);
    expect(find.textContaining('30 秒'), findsOneWidget);
  });

  testWidgets('未标定的麦克风给出精度提示', (tester) async {
    await pumpDashboard(tester, Telemetry.fromJson(snapshotJson()));
    expect(find.textContaining('未标定'), findsOneWidget);
  });

  testWidgets('未接入的传感器显示占位符', (tester) async {
    await pumpDashboard(tester, Telemetry.fromJson(snapshotJson()));
    // lux 的 health 是 absent
    expect(find.text('未接入'), findsOneWidget);
  });

  testWidgets('无人时提示监测已暂停 —— 没人不打扰', (tester) async {
    final t = Telemetry.fromJson(snapshotJson(presenceState: 'absent'));
    await pumpDashboard(tester, t);

    expect(find.text('无人在座 · 监测已暂停'), findsOneWidget);
    expect(find.text('无人'), findsOneWidget);
    // 不该再显示「建议开窗」之类的行动建议
    expect(find.textContaining('建议开窗'), findsNothing);
  });

  testWidgets('实时推送会刷新界面', (tester) async {
    final fake = await pumpDashboard(
      tester,
      Telemetry.fromJson(snapshotJson(riskLevel: 'good', drivers: [])),
    );
    expect(find.text('良好'), findsOneWidget);

    fake.push(
      Telemetry.fromJson(
        snapshotJson(
          riskLevel: 'bad',
          drivers: ['co2'],
          co2: {'value': 2100, 'unit': 'ppm', 'level': 'bad', 'health': 'ok'},
          seq: 2,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('很差'), findsOneWidget);
    expect(find.text('2100 ppm'), findsOneWidget);
  });

  testWidgets('告警弹出横幅', (tester) async {
    final fake = await pumpDashboard(tester, Telemetry.fromJson(snapshotJson()));

    fake.pushAlert(
      const Alert(
        id: 'alert_co2',
        ruleId: 'rule_co2_high',
        deviceId: 'mmr-a00000000001',
        metric: Metric.co2,
        level: RiskLevel.poor,
        value: 1320,
        unit: 'ppm',
        message: '空气浑浊 · 建议开窗通风',
        isActive: true,
        raisedAt: 1700000000,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('连接状态在标题栏可见', (tester) async {
    final fake = await pumpDashboard(tester, Telemetry.fromJson(snapshotJson()));

    // 流事件经微任务投递，pump 两次确保 Provider 已收到并重建
    fake.pushStatus(ChannelState.connected);
    await tester.pump();
    await tester.pump();
    expect(find.text('已连接'), findsOneWidget);

    fake.pushStatus(ChannelState.reconnecting);
    await tester.pump();
    await tester.pump();
    expect(find.text('重连中'), findsOneWidget);
  });

  testWidgets('下拉刷新会请求全量快照', (tester) async {
    final fake = await pumpDashboard(tester, Telemetry.fromJson(snapshotJson()));

    await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();

    expect(fake.sentCommands, contains('get_snapshot'));
  });
}
