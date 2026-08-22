/// 工位标定：引导式，不暴露「距离门」。
///
/// 用户要表达的是「我平时坐在这儿」，而不是「把距离门设成 38–98 厘米」。
/// 后者要求用户先理解雷达怎么工作、再自己换算 —— 而他们既不想懂也不该懂。
///
/// 这件事为什么值得单独做一页：**在场判定的准确度几乎全靠这一步**。
/// 区间标歪了，路过的人会被当成在座（假阳），或者本人静坐时被判离座（假阴）。
/// 后者尤其糟 —— 久坐提醒会在你坐了两小时后才想起来。
///
/// 关键约束：**标定时用户必须真的坐在工位上**。
/// 拿着手机站在设备旁边点一下，标出来的是站姿的距离，日常使用时全错。
/// 所以这一页把实时读数摆在最显眼的位置，让用户自己看见「它认到我了」，
/// 而不是点完按钮听天由命。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/contracts/command.dart';
import '../../core/contracts/telemetry.dart';
import '../../data/device_channel.dart';
import '../../data/providers.dart';

/// 标定前的检查结果。
///
/// 抽成纯函数是因为它有分支、会出错、且每一条都对应一种用户看得见的失败。
/// UI 那一层只负责把它画出来。
enum ZoneReadiness {
  /// 可以标定。
  ready,

  /// 雷达没探到人 —— 多半是用户没坐下，或者坐得太远。
  noTarget,

  /// 雷达本身有问题，标定无从谈起。
  sensorUnavailable,

  /// 还没收到任何遥测。
  noData;

  bool get canCalibrate => this == ZoneReadiness.ready;
}

/// 判断当前能不能标定。
///
/// [telemetry] 为 null 表示还没收到数据。
ZoneReadiness zoneReadiness(Telemetry? telemetry) {
  if (telemetry == null) return ZoneReadiness.noData;

  final p = telemetry.presence;

  // 传感器不可用时读数没有意义。注意 degraded 仍然放行 ——
  // 有偏差的距离也比没有强，而且用户能从实时读数上看出不对。
  if (!(p.health == SensorHealth.ok || p.health == SensorHealth.degraded)) {
    return ZoneReadiness.sensorUnavailable;
  }

  // 没人、或者没有有效距离 —— 后者在契约里是 null，不是 0。
  final d = p.distanceCm;
  if (!p.isPresent || d == null || d <= 0) return ZoneReadiness.noTarget;

  return ZoneReadiness.ready;
}

/// 设备端 `calibrate_zone` 在当前距离两侧各留的余量（厘米）。
const zoneMarginCm = 30;

/// LD2411S 的可信量程，标定结果会被夹在这个范围内。
///
/// 与固件 `PresenceTracker::calibrate_zone` 的常量必须一致
/// （`components/mmr_core/src/presence.cpp`）。
const zoneMinCm = 30;
const zoneMaxCm = 600;

/// 标定后的区间，用于在按钮按下前告诉用户会发生什么。
///
/// ⚠️ 这是把设备端的算法**又算了一遍**，两处必然有分叉的风险。
/// 之所以还是算：不预告的话，用户点下去之前不知道会发生什么，
/// 而这一步直接决定在场判定准不准。
///
/// 代价是真实的 —— 第一版这里写的是「下界夹到 10，上界不夹」，
/// 与固件的 30/600 对不上，预告会在近距离和远距离两端都撒谎。
/// 所以常量要照抄固件，边界值要有测试。
({int minCm, int maxCm}) previewZone(int distanceCm) => (
  minCm: (distanceCm - zoneMarginCm).clamp(zoneMinCm, zoneMaxCm),
  maxCm: (distanceCm + zoneMarginCm).clamp(zoneMinCm, zoneMaxCm),
);

class ZoneCalibrationPage extends ConsumerWidget {
  const ZoneCalibrationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final telemetry = ref.watch(telemetryProvider);
    final latest = telemetry.value;
    final readiness = zoneReadiness(latest);

    return Scaffold(
      appBar: AppBar(title: const Text('标定工位')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '请像平时办公那样坐好，然后点下面的按钮。',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '设备会把你现在的位置记为工位，前后各留 $zoneMarginCm 厘米余量。'
            '这样路过的人不会被算成「你在工位上」。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          _LiveReading(readiness: readiness, presence: latest?.presence),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('zone-calibrate-button'),
            // 条件不满足就禁用，而不是让用户点了再报错 ——
            // 报错要读，禁用配上上面那行实时读数是自明的。
            onPressed: readiness.canCalibrate ? () => _calibrate(context, ref) : null,
            icon: const Icon(Icons.my_location),
            label: const Text('就用现在这个位置'),
          ),
        ],
      ),
    );
  }
}

/// 实时读数。
///
/// 这一块是整页的重点：用户得先看见「设备认到我了」，
/// 才可能标出一个对的区间。
class _LiveReading extends StatelessWidget {
  const _LiveReading({required this.readiness, required this.presence});

  final ZoneReadiness readiness;
  final Presence? presence;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, title, detail, tone) = switch (readiness) {
      ZoneReadiness.ready => (
        Icons.check_circle_outline,
        '已探测到你，距离 ${presence!.distanceCm} 厘米',
        () {
          final z = previewZone(presence!.distanceCm!);
          return '标定后的工位范围约为 ${z.minCm}–${z.maxCm} 厘米';
        }(),
        scheme.primary,
      ),
      ZoneReadiness.noTarget => (
        Icons.person_search_outlined,
        '还没探测到你',
        '请坐到平时的位置上。如果一直没反应，可能是坐得太远，或者设备没对着你。',
        scheme.error,
      ),
      ZoneReadiness.sensorUnavailable => (
        Icons.sensors_off_outlined,
        '雷达当前不可用',
        '设备的在场传感器没有正常工作，先解决这个问题再标定。',
        scheme.error,
      ),
      ZoneReadiness.noData => (
        Icons.hourglass_empty,
        '正在读取设备数据…',
        '如果一直停在这里，先回设置页确认设备连上了。',
        scheme.outline,
      ),
    };

    return Card(
      key: const Key('zone-live-reading'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: tone, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(
                      context,
                    ).textTheme.titleSmall?.copyWith(color: tone),
                  ),
                  const SizedBox(height: 4),
                  Text(detail, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _calibrate(BuildContext context, WidgetRef ref) async {
  // 全部在 await 之前取好：await 之后 context 可能已经失效
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final errorColor = Theme.of(context).colorScheme.error;

  final result = await ref.read(channelProvider).calibrateZone();
  messenger.clearSnackBars();

  switch (result) {
    case CommandOk():
      messenger.showSnackBar(const SnackBar(content: Text('工位已标定')));
      // 标完就退出：用户的目标是「标定」，不是「停留在标定页」。
      navigator.pop();
    case CommandFailed(:final error):
      // 显示设备给的具体原因。设备可能因为标定瞬间人又走开了而拒绝，
      // 那种情况下「保存失败」四个字帮不上任何忙。
      messenger.showSnackBar(
        SnackBar(content: Text(error.display), backgroundColor: errorColor),
      );
  }
}
