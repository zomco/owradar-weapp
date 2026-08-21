/// 规则模板。
///
/// 规则配置**模板优先**，不让用户从零搭建 —— 见 04-app-architecture.md §6.3。
///
/// 「持续时长」「滞回」「冷却期」这些概念对普通用户完全陌生，
/// 但它们又恰恰是让告警不烦人的关键。模板把这些参数预设成合理值，
/// 用户只需要决定「要不要开」和「阈值多少」。
library;

import 'contracts/rule.dart';
import 'contracts/telemetry.dart';

class RuleTemplate {
  const RuleTemplate({
    required this.id,
    required this.title,
    required this.description,
    required this.metric,
    required this.op,
    required this.defaultThreshold,
    required this.severity,
    required this.screenText,
    required this.durationS,
    required this.hysteresis,
    required this.cooldownS,
    this.thresholdMin = 0,
    this.thresholdMax = 100,
    this.thresholdStep = 1,
    this.requiresPresence = true,
  });

  final String id;
  final String title;

  /// 一句话说清「什么时候会提醒我」。用户看这句就够了。
  final String description;

  final Metric metric;
  final RuleOp op;
  final double defaultThreshold;
  final double thresholdMin;
  final double thresholdMax;
  final double thresholdStep;
  final RiskLevel severity;
  final String screenText;

  /// 以下三项是「让告警不烦人」的关键，模板预设好，高级模式才暴露。
  final int durationS;
  final double hysteresis;
  final int cooldownS;

  final bool requiresPresence;

  Rule toRule({double? threshold}) => Rule(
    id: id,
    name: title,
    metric: metric,
    op: op,
    threshold: threshold ?? defaultThreshold,
    durationS: durationS,
    hysteresis: hysteresis,
    requiresPresence: requiresPresence,
    severity: severity,
    cooldownS: cooldownS,
    actions: [
      RuleAction(type: ActionType.screen, config: {'text': screenText}),
    ],
  );
}

/// 预置模板。覆盖桌面场景 90% 的需求。
///
/// 文案与固件的出厂规则保持一致 —— 用户在 App 里看到的
/// 和设备屏幕上显示的应当是同一句话。
const List<RuleTemplate> kRuleTemplates = [
  RuleTemplate(
    id: 'rule_co2_high',
    title: 'CO₂ 超标提醒',
    description: '你在座时二氧化碳持续偏高，提醒开窗通风',
    metric: Metric.co2,
    op: RuleOp.gt,
    defaultThreshold: 1200,
    thresholdMin: 800,
    thresholdMax: 2500,
    thresholdStep: 50,
    severity: RiskLevel.poor,
    screenText: '空气浑浊 · 建议开窗通风',
    // 5 分钟去抖：CO2 会随一次深呼吸短暂跳高，不该立刻报
    durationS: 300,
    // 回落 100ppm 才解除，防止在阈值附近反复告警
    hysteresis: 100,
    cooldownS: 1800,
  ),
  RuleTemplate(
    id: 'rule_noise_high',
    title: '环境嘈杂提醒',
    description: '周围持续吵闹时提醒你，影响专注',
    metric: Metric.noise,
    op: RuleOp.gt,
    defaultThreshold: 65,
    thresholdMin: 50,
    thresholdMax: 85,
    thresholdStep: 1,
    severity: RiskLevel.fair,
    screenText: '环境嘈杂 · 影响专注',
    durationS: 120,
    hysteresis: 5,
    cooldownS: 3600,
  ),
  RuleTemplate(
    id: 'rule_temp_high',
    title: '温度过高提醒',
    description: '室温超过舒适区时提醒，注意通风或空调',
    metric: Metric.temperature,
    op: RuleOp.gt,
    defaultThreshold: 28,
    thresholdMin: 24,
    thresholdMax: 35,
    thresholdStep: 1,
    severity: RiskLevel.fair,
    screenText: '温度偏高 · 注意调节',
    durationS: 600,
    hysteresis: 1,
    cooldownS: 3600,
  ),
  RuleTemplate(
    id: 'rule_humidity_low',
    title: '空气干燥提醒',
    description: '湿度过低时提醒，长时间干燥影响呼吸道',
    metric: Metric.humidity,
    op: RuleOp.lt,
    defaultThreshold: 30,
    thresholdMin: 20,
    thresholdMax: 45,
    thresholdStep: 1,
    severity: RiskLevel.fair,
    screenText: '空气干燥 · 建议加湿',
    durationS: 900,
    hysteresis: 3,
    cooldownS: 7200,
  ),
  RuleTemplate(
    id: 'rule_lux_low',
    title: '光线不足提醒',
    description: '桌面照度偏低时提醒开灯，避免用眼疲劳',
    metric: Metric.lux,
    op: RuleOp.lt,
    defaultThreshold: 200,
    thresholdMin: 50,
    thresholdMax: 400,
    thresholdStep: 10,
    severity: RiskLevel.fair,
    screenText: '光线不足 · 建议开灯',
    durationS: 300,
    hysteresis: 30,
    cooldownS: 3600,
  ),
];

RuleTemplate? templateFor(String ruleId) {
  for (final t in kRuleTemplates) {
    if (t.id == ruleId) return t;
  }
  return null;
}

/// 把规则渲染成一句人话，用于列表。
///
/// 比起「co2 gt 1200 duration 300」，用户要看的是
/// 「你在座时，二氧化碳超过 1200 ppm 持续 5 分钟就提醒」。
String describeRule(Rule rule) {
  final metric = _metricNoun(rule.metric);
  final unit = _unit(rule.metric);
  final cmp = switch (rule.op) {
    RuleOp.gt => '超过',
    RuleOp.lt => '低于',
    RuleOp.outside => '超出',
  };
  final value = rule.threshold == rule.threshold.roundToDouble()
      ? rule.threshold.toStringAsFixed(0)
      : rule.threshold.toStringAsFixed(1);

  final prefix = rule.requiresPresence ? '你在座时，' : '';
  final hold = rule.durationS >= 60
      ? '持续 ${rule.durationS ~/ 60} 分钟'
      : rule.durationS > 0
      ? '持续 ${rule.durationS} 秒'
      : '';

  return '$prefix$metric$cmp $value$unit${hold.isEmpty ? '' : ' $hold'}就提醒';
}

String _metricNoun(Metric m) => switch (m) {
  Metric.co2 => '二氧化碳',
  Metric.temperature => '温度',
  Metric.humidity => '湿度',
  Metric.noise => '噪音',
  Metric.lux => '光照',
};

String _unit(Metric m) => switch (m) {
  Metric.co2 => ' ppm',
  Metric.temperature => '°C',
  Metric.humidity => '%',
  Metric.noise => ' dBA',
  Metric.lux => ' lx',
};
