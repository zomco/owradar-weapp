/// 工位标定。
///
/// 这一页守的是一条产品判断：**「距离门」不该出现在用户面前**。
/// 用户要表达的是「我平时坐这儿」，设备负责把它翻译成厘米区间。
///
/// 另一条同样要紧：标定必须在**用户真的坐着**的时候进行。
/// 站在设备旁边点一下，标出来的是站姿距离，日常使用时全错 ——
/// 所以没探到人时按钮必须是禁用的，而不是点了再报错。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmradar_app/core/contracts/telemetry.dart';
import 'package:mmradar_app/data/providers.dart';
import 'package:mmradar_app/features/settings/zone_calibration.dart';

import 'contracts_test.dart' show snapshotJson;

Telemetry _telemetry({
  String presenceState = 'present_still',
  int? distanceCm = 68,
  String health = 'ok',
}) {
  final json = snapshotJson(presenceState: presenceState);
  // 造一份新的 map 而不是改原来那个：snapshotJson 里的内层字面量
  // 被推断成 Map<String, Object>（值全非空），往里写 null 会在运行期炸。
  json['presence'] = <String, Object?>{
    ...(json['presence']! as Map).cast<String, Object?>(),
    'distance_cm': distanceCm,
    'health': health,
  };
  return Telemetry.fromJson(json);
}

Future<void> _pump(WidgetTester tester, Telemetry? telemetry) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        telemetryProvider.overrideWith(
          (ref) => telemetry == null ? const Stream<Telemetry>.empty() : Stream.value(telemetry),
        ),
      ],
      child: const MaterialApp(home: ZoneCalibrationPage()),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

void main() {
  group('标定前的条件判断', () {
    test('坐着且有距离时可以标定', () {
      expect(zoneReadiness(_telemetry()), ZoneReadiness.ready);
    });

    test('没人时不能标定', () {
      // 用户还没坐下就点，标出来的会是空工位的距离
      expect(
        zoneReadiness(_telemetry(presenceState: 'absent', distanceCm: null)),
        ZoneReadiness.noTarget,
      );
    });

    test('在场但没有有效距离时不能标定', () {
      expect(zoneReadiness(_telemetry(distanceCm: null)), ZoneReadiness.noTarget);
    });

    test('距离为 0 或负数按无效处理', () {
      // 契约规定「无距离」用 null 表示，但固件曾用 -1；
      // 两种都挡住，免得标出一个 -30～30 的荒唐区间
      for (final d in [0, -1]) {
        expect(zoneReadiness(_telemetry(distanceCm: d)), ZoneReadiness.noTarget);
      }
    });

    test('雷达故障或缺席时不能标定', () {
      for (final h in ['fault', 'absent', 'warming_up']) {
        expect(
          zoneReadiness(_telemetry(health: h)),
          ZoneReadiness.sensorUnavailable,
          reason: 'health=$h 时读数不可信',
        );
      }
    });

    test('degraded 仍可标定 —— 有偏差的距离也好过没有', () {
      expect(zoneReadiness(_telemetry(health: 'degraded')), ZoneReadiness.ready);
    });

    test('还没有数据时既不是可用也不是没人', () {
      // 区分这两者是有意义的：一个要等，一个要用户动一动
      expect(zoneReadiness(null), ZoneReadiness.noData);
    });
  });

  group('区间预告', () {
    test('前后各留 30 厘米', () {
      final z = previewZone(68);
      expect(z.minCm, 38);
      expect(z.maxCm, 98);
    });

    test('近距离时下界夹到雷达量程下限', () {
      // 固件 PresenceTracker::calibrate_zone 夹到 30，不是 0 也不是 10。
      // 第一版这里写错过：预告说 10，设备实际给 30，用户被骗一次。
      final z = previewZone(35);
      expect(z.minCm, 30);
      expect(z.maxCm, 65);
    });

    test('远距离时上界夹到雷达量程上限', () {
      final z = previewZone(590);
      expect(z.minCm, 560);
      expect(z.maxCm, 600);
    });

    test('预告与固件的常量一致', () {
      // 这两个数照抄 components/mmr_core/src/presence.cpp。
      // 固件改了量程而这里没跟，预告就会撒谎 —— 这条至少能让它红。
      expect(zoneMinCm, 30);
      expect(zoneMaxCm, 600);
      expect(zoneMarginCm, 30);
    });
  });

  group('界面', () {
    testWidgets('探测到人时显示距离与预告区间', (tester) async {
      await _pump(tester, _telemetry());

      expect(find.textContaining('68 厘米'), findsOneWidget);
      expect(find.textContaining('38–98 厘米'), findsOneWidget);
    });

    testWidgets('没探到人时按钮禁用', (tester) async {
      // 关键：不是让用户点了再报错。报错要读，禁用配上实时读数是自明的。
      await _pump(tester, _telemetry(presenceState: 'absent', distanceCm: null));

      final button = tester.widget<FilledButton>(find.byKey(const Key('zone-calibrate-button')));
      expect(button.onPressed, isNull);
      expect(find.textContaining('还没探测到你'), findsOneWidget);
    });

    testWidgets('探测到人时按钮可用', (tester) async {
      await _pump(tester, _telemetry());

      final button = tester.widget<FilledButton>(find.byKey(const Key('zone-calibrate-button')));
      expect(button.onPressed, isNotNull);
    });

    testWidgets('雷达故障时说明是传感器的问题，不是没坐好', (tester) async {
      // 两种失败的用户动作完全不同：一个是「坐下」，一个是「修设备」。
      // 都说「还没探测到你」会让用户在椅子上白挪半天。
      await _pump(tester, _telemetry(health: 'fault'));

      expect(find.textContaining('雷达当前不可用'), findsOneWidget);
      expect(find.textContaining('还没探测到你'), findsNothing);
    });

    testWidgets('整页不出现「距离门」这个词', (tester) async {
      // 这是这一页存在的全部理由。将来有人图省事加一句
      //「当前距离门 38-98」，这条会红。
      await _pump(tester, _telemetry());

      expect(find.textContaining('距离门'), findsNothing);
    });
  });
}
