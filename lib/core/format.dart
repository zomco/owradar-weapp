/// 展示逻辑：读数怎么显示、风险配色、建议文案。
///
/// **与固件的 `components/mmr_ui/src/format.cpp` 同源。**
/// 同一个 level 在屏幕、App、HA、云上必须是同一个颜色，
/// 同一个 health 必须显示同样的语义 —— 两边改动要同步。
///
/// 纯逻辑，不依赖 Flutter，可脱离 widget 单测。
library;

import 'contracts/telemetry.dart';

/// 四档风险配色（0xRRGGBB）。取自固件 format.cpp 的 risk_color()。
int riskColorValue(RiskLevel level) => switch (level) {
  RiskLevel.good => 0x1E8E4E,
  RiskLevel.fair => 0x0E7C86,
  RiskLevel.poor => 0xC08A00,
  RiskLevel.bad => 0xB3261E,
};

String riskTitle(RiskLevel level) => switch (level) {
  RiskLevel.good => '良好',
  RiskLevel.fair => '一般',
  RiskLevel.poor => '较差',
  RiskLevel.bad => '很差',
};

/// 一句可执行的建议。
///
/// 按「用户能否立刻采取行动」排序，而不是按指标严重程度：
/// CO₂ 最前 —— 开窗就能解决，且它是随在场时长单调累积的锚点指标。
String riskHint(RiskLevel level, List<Metric> drivers) {
  if (level == RiskLevel.good) return '环境良好';
  if (drivers.contains(Metric.co2)) {
    return level.severity >= RiskLevel.poor.severity ? '空气浑浊 · 建议开窗通风' : '二氧化碳偏高';
  }
  if (drivers.contains(Metric.temperature)) return '温度不适 · 注意调节';
  if (drivers.contains(Metric.humidity)) return '湿度不适 · 注意调节';
  if (drivers.contains(Metric.noise)) {
    return level.severity >= RiskLevel.poor.severity ? '环境嘈杂 · 影响专注' : '环境略吵';
  }
  if (drivers.contains(Metric.lux)) return '光线不适 · 注意用眼';
  return '环境异常';
}

String metricLabel(Metric m) => switch (m) {
  Metric.co2 => '二氧化碳',
  Metric.temperature => '温度',
  Metric.humidity => '湿度',
  Metric.noise => '噪音',
  Metric.lux => '光照',
};

/// 单位的展示形式。契约里的 unit 是机器可读的小写串（`c`/`pct`/`dba`），
/// 直接显示给用户不合适。
String unitLabel(Metric m) => switch (m) {
  Metric.co2 => 'ppm',
  Metric.temperature => '°C',
  Metric.humidity => '%',
  Metric.noise => 'dBA',
  Metric.lux => 'lx',
};

/// 读数的展示结果。UI 直接用它渲染，不再自己判断 health。
class ReadingDisplay {
  const ReadingDisplay({required this.text, required this.isPlaceholder, required this.note});

  /// 要显示的主文本。可能是数值，也可能是「预热中」这类状态词。
  final String text;

  /// true 表示这不是一个真实数值，UI 应当弱化显示。
  final bool isPlaceholder;

  /// 补充说明，没有则为空串。
  final String note;
}

/// 把读数格式化成可显示的内容。
///
/// health 非 ok 时显示状态而不是陈旧值 ——
/// **用户必须能一眼分辨「传感器坏了」和「数值正常」**，
/// 继续显示上一个有效值是最危险的做法。
ReadingDisplay formatReading(Reading r, Metric m) {
  switch (r.health) {
    case SensorHealth.warmingUp:
      return const ReadingDisplay(text: '预热中', isPlaceholder: true, note: '传感器启动后约 30 秒可用');
    case SensorHealth.fault:
      return const ReadingDisplay(text: '故障', isPlaceholder: true, note: '传感器读取失败');
    case SensorHealth.absent:
      return const ReadingDisplay(text: '—', isPlaceholder: true, note: '未接入');
    case SensorHealth.ok:
    case SensorHealth.degraded:
      break;
  }

  final v = r.value;
  if (v == null) {
    return const ReadingDisplay(text: '—', isPlaceholder: true, note: '');
  }

  // 只有温度需要小数位；其余指标的小数位没有信息量。
  final digits = m == Metric.temperature ? 1 : 0;
  final text = '${v.toStringAsFixed(digits)} ${unitLabel(m)}';

  return ReadingDisplay(
    text: text,
    isPlaceholder: false,
    // degraded 仍显示数值，但要让用户知道精度存疑（典型是麦克风未标定）
    note: r.health == SensorHealth.degraded ? '未标定，数值仅供参考' : '',
  );
}

/// 在座时长。超过一小时用「1 小时 32 分」，否则只说分钟。
String formatSeated(int seconds) {
  if (seconds < 60) return '刚落座';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h == 0) return '已在座 $m 分钟';
  return '已在座 $h 小时 $m 分';
}

String presenceLabel(PresenceState s) => switch (s) {
  PresenceState.absent => '无人',
  PresenceState.presentStill => '在座',
  PresenceState.presentMoving => '在座（活动中）',
};

/// 距离的展示。absent 时没有距离，契约里是 null。
String formatDistance(int? cm) => cm == null ? '—' : '$cm cm';

String linkLabel(LinkState s) => switch (s) {
  LinkState.connected => '已连接',
  LinkState.connecting => '连接中',
  LinkState.disabled => '未启用',
  LinkState.error => '异常',
};
