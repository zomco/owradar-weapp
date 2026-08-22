/// 规则的 Dart 映射。见 workspace/contracts/rule.schema.json。
library;

import 'telemetry.dart';

enum RuleOp {
  gt,
  lt,
  outside;

  static RuleOp parse(Object? v) =>
      RuleOp.values.firstWhere((e) => e.name == v, orElse: () => RuleOp.gt);
}

enum ActionType {
  screen,
  webhook,
  telegram,
  discord,
  feishu,
  haService,
  mqttPublish;

  static const _wire = {
    'screen': ActionType.screen,
    'webhook': ActionType.webhook,
    'telegram': ActionType.telegram,
    'discord': ActionType.discord,
    'feishu': ActionType.feishu,
    'ha_service': ActionType.haService,
    'mqtt_publish': ActionType.mqttPublish,
  };

  static const _toWire = {
    ActionType.screen: 'screen',
    ActionType.webhook: 'webhook',
    ActionType.telegram: 'telegram',
    ActionType.discord: 'discord',
    ActionType.feishu: 'feishu',
    ActionType.haService: 'ha_service',
    ActionType.mqttPublish: 'mqtt_publish',
  };

  static ActionType parse(Object? v) => _wire[v] ?? ActionType.screen;

  String get wire => _toWire[this]!;

  String get label => switch (this) {
    ActionType.screen => '屏幕提示',
    ActionType.webhook => 'Webhook',
    ActionType.telegram => 'Telegram',
    ActionType.discord => 'Discord',
    ActionType.feishu => '飞书',
    ActionType.haService => 'Home Assistant',
    ActionType.mqttPublish => 'MQTT',
  };
}

class RuleAction {
  const RuleAction({required this.type, required this.config});

  final ActionType type;

  /// **凭证绝不出现在这里** —— 用 channel_ref 指向单独存储的条目。
  /// 规则对象会在 App、云、HA、设备之间来回传输。
  final Map<String, Object?> config;

  String get text => config['text'] as String? ?? '';
  String? get channelRef => config['channel_ref'] as String?;

  factory RuleAction.fromJson(Map<String, Object?> j) => RuleAction(
    type: ActionType.parse(j['type']),
    config: (j['config'] as Map?)?.cast<String, Object?>() ?? const {},
  );

  Map<String, Object?> toJson() => {'type': type.wire, 'config': config};
}

class Rule {
  const Rule({
    required this.id,
    required this.metric,
    required this.op,
    required this.threshold,
    required this.severity,
    required this.actions,
    this.name = '',
    this.isEnabled = true,
    this.thresholdHigh,
    this.durationS = 0,
    this.hysteresis = 0,
    this.requiresPresence = true,
    this.cooldownS = 1800,
  });

  final String id;
  final String name;
  final bool isEnabled;
  final Metric metric;
  final RuleOp op;
  final double threshold;
  final double? thresholdHigh;

  /// 条件需持续满足多久才触发。去抖，防止瞬时尖峰误报。
  final int durationS;

  /// 解除时的回差。防止读数在阈值附近震荡产生告警风暴。
  final double hysteresis;

  /// **无人时不触发** —— 本产品区别于普通空气检测仪的核心语义。
  final bool requiresPresence;
  final RiskLevel severity;
  final int cooldownS;
  final List<RuleAction> actions;

  factory Rule.fromJson(Map<String, Object?> j) => Rule(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    isEnabled: j['is_enabled'] as bool? ?? true,
    metric: Metric.tryParse(j['metric']) ?? Metric.co2,
    op: RuleOp.parse(j['op']),
    threshold: (j['threshold'] as num?)?.toDouble() ?? 0,
    thresholdHigh: (j['threshold_high'] as num?)?.toDouble(),
    durationS: (j['duration_s'] as num?)?.toInt() ?? 0,
    hysteresis: (j['hysteresis'] as num?)?.toDouble() ?? 0,
    requiresPresence: j['requires_presence'] as bool? ?? true,
    severity: RiskLevel.parse(j['severity']),
    cooldownS: (j['cooldown_s'] as num?)?.toInt() ?? 1800,
    actions: ((j['actions'] as List?) ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((a) => RuleAction.fromJson(a.cast<String, Object?>()))
        .toList(),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'is_enabled': isEnabled,
    'metric': metric.name,
    'op': op.name,
    'threshold': threshold,
    'threshold_high': thresholdHigh,
    'duration_s': durationS,
    'hysteresis': hysteresis,
    'requires_presence': requiresPresence,
    'severity': severity.name,
    'cooldown_s': cooldownS,
    'actions': actions.map((a) => a.toJson()).toList(),
  };

  Rule copyWith({
    String? name,
    bool? isEnabled,
    double? threshold,
    int? durationS,
    bool? requiresPresence,
  }) => Rule(
    id: id,
    name: name ?? this.name,
    isEnabled: isEnabled ?? this.isEnabled,
    metric: metric,
    op: op,
    threshold: threshold ?? this.threshold,
    thresholdHigh: thresholdHigh,
    durationS: durationS ?? this.durationS,
    hysteresis: hysteresis,
    requiresPresence: requiresPresence ?? this.requiresPresence,
    severity: severity,
    cooldownS: cooldownS,
    actions: actions,
  );
}
