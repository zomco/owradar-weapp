/// 契约层的 Dart 映射。
///
/// 权威定义在工作区的 `contracts/telemetry.schema.json`。
/// 改这里之前先改契约 —— 见 workspace/CLAUDE.md §1。
library;

const int kSchemaVersion = 1;

/// 风险等级。四档，全系统统一。
enum RiskLevel {
  good,
  fair,
  poor,
  bad;

  /// 未知值一律降级为 good 而不是抛异常 ——
  /// 设备固件可能比 App 新，多出来的枚举值不该让整个界面白屏。
  static RiskLevel parse(Object? v) =>
      RiskLevel.values.firstWhere((e) => e.name == v, orElse: () => RiskLevel.good);

  /// 严重程度排序，用于取最差档。
  int get severity => index;
}

enum PresenceState {
  absent,
  presentStill,
  presentMoving;

  static const _wire = {
    'absent': PresenceState.absent,
    'present_still': PresenceState.presentStill,
    'present_moving': PresenceState.presentMoving,
  };

  static PresenceState parse(Object? v) => _wire[v] ?? PresenceState.absent;

  bool get isPresent => this != PresenceState.absent;
}

enum Metric {
  co2,
  temperature,
  humidity,
  noise,
  lux;

  static Metric? tryParse(Object? v) {
    for (final m in Metric.values) {
      if (m.name == v) return m;
    }
    return null;
  }
}

enum SensorHealth {
  ok,
  warmingUp,
  degraded,
  fault,
  absent;

  static const _wire = {
    'ok': SensorHealth.ok,
    'warming_up': SensorHealth.warmingUp,
    'degraded': SensorHealth.degraded,
    'fault': SensorHealth.fault,
    'absent': SensorHealth.absent,
  };

  static SensorHealth parse(Object? v) => _wire[v] ?? SensorHealth.absent;

  /// 数值是否可用于展示与聚合。
  /// degraded 算可用 —— 有偏差的数好过没有数，UI 会另行标注。
  bool get usable => this == SensorHealth.ok || this == SensorHealth.degraded;
}

enum LinkState {
  connected,
  connecting,
  disabled,
  error;

  static LinkState parse(Object? v) =>
      LinkState.values.firstWhere((e) => e.name == v, orElse: () => LinkState.disabled);
}

/// 单个环境指标的读数。形状对全部指标一致，UI 不做特例。
class Reading {
  const Reading({
    required this.value,
    required this.unit,
    required this.level,
    required this.health,
  });

  /// health 非 ok 时可能为 null。契约要求缺失一律用 null，不用 0/-1/-999。
  final double? value;
  final String unit;

  /// **由设备端分级，客户端不重复计算** ——
  /// 各端各算一遍会出现「手机上是绿的、屏幕上是红的」。
  final RiskLevel level;
  final SensorHealth health;

  bool get usable => value != null && health.usable;

  static const Reading unavailable = Reading(
    value: null,
    unit: '',
    level: RiskLevel.good,
    health: SensorHealth.absent,
  );

  factory Reading.fromJson(Map<String, Object?> j) => Reading(
    value: (j['value'] as num?)?.toDouble(),
    unit: j['unit'] as String? ?? '',
    level: RiskLevel.parse(j['level']),
    health: SensorHealth.parse(j['health']),
  );
}

class Presence {
  const Presence({
    required this.state,
    required this.distanceCm,
    required this.inZone,
    required this.seatedDurationS,
    required this.health,
    this.stateSinceAt,
  });

  final PresenceState state;

  /// absent 时为 null。契约里同样禁止用 0 表示「无距离」。
  final int? distanceCm;

  /// 是否落在用户标定的目标区域内。**瞬时值**，
  /// 规则的在场判定用的是去抖后的 [state]（见固件 rules.cpp 的注释）。
  final bool inZone;
  final int seatedDurationS;
  final SensorHealth health;
  final int? stateSinceAt;

  bool get isPresent => state.isPresent;

  static const Presence empty = Presence(
    state: PresenceState.absent,
    distanceCm: null,
    inZone: false,
    seatedDurationS: 0,
    health: SensorHealth.absent,
  );

  factory Presence.fromJson(Map<String, Object?> j) => Presence(
    state: PresenceState.parse(j['state']),
    distanceCm: (j['distance_cm'] as num?)?.toInt(),
    inZone: j['in_zone'] as bool? ?? false,
    seatedDurationS: (j['seated_duration_s'] as num?)?.toInt() ?? 0,
    health: SensorHealth.parse(j['health']),
    stateSinceAt: (j['state_since_at'] as num?)?.toInt(),
  );
}

class DeviceInfo {
  const DeviceInfo({
    required this.fwVersion,
    this.rssiDbm,
    this.wifiSsid,
    this.batteryPct,
    this.isCharging,
    this.freeHeapBytes,
  });

  final String fwVersion;
  final int? rssiDbm;
  final String? wifiSsid;

  /// 格子派底板把充电状态接到指示灯而非 GPIO，软件读不到，恒为 null。
  final int? batteryPct;
  final bool? isCharging;
  final int? freeHeapBytes;

  factory DeviceInfo.fromJson(Map<String, Object?> j) => DeviceInfo(
    fwVersion: j['fw_version'] as String? ?? '未知',
    rssiDbm: (j['rssi_dbm'] as num?)?.toInt(),
    wifiSsid: j['wifi_ssid'] as String?,
    batteryPct: (j['battery_pct'] as num?)?.toInt(),
    isCharging: j['is_charging'] as bool?,
    freeHeapBytes: (j['free_heap_bytes'] as num?)?.toInt(),
  );
}

class Links {
  const Links({required this.cloud, required this.mqtt, required this.local});

  final LinkState cloud;
  final LinkState mqtt;
  final LinkState local;

  static const Links unknown = Links(
    cloud: LinkState.disabled,
    mqtt: LinkState.disabled,
    local: LinkState.disabled,
  );

  factory Links.fromJson(Map<String, Object?> j) => Links(
    cloud: LinkState.parse(j['cloud']),
    mqtt: LinkState.parse(j['mqtt']),
    local: LinkState.parse(j['local']),
  );
}

/// 设备完整状态快照。UI 永远只面对这个完整对象 ——
/// Delta 的合并在 Channel 层完成（见 04-app-architecture.md §3）。
class Telemetry {
  const Telemetry({
    required this.deviceId,
    required this.seq,
    required this.uptimeS,
    required this.presence,
    required this.env,
    required this.riskLevel,
    required this.riskDrivers,
    required this.activeAlertIds,
    required this.device,
    required this.links,
    this.at,
  });

  final String deviceId;

  /// 单调递增。不连续说明丢包，Channel 层会请求全量快照重新对齐。
  final int seq;
  final int uptimeS;
  final int? at;

  final Presence presence;
  final Map<Metric, Reading> env;

  final RiskLevel riskLevel;

  /// 导致当前风险等级的指标，可多个。UI 用它决定高亮哪几行。
  final List<Metric> riskDrivers;
  final List<String> activeAlertIds;

  final DeviceInfo device;
  final Links links;

  Reading reading(Metric m) => env[m] ?? Reading.unavailable;

  bool get hasActiveAlert => activeAlertIds.isNotEmpty;

  factory Telemetry.fromJson(Map<String, Object?> j) {
    final envJson = j['env'];
    final env = <Metric, Reading>{};
    if (envJson is Map) {
      for (final m in Metric.values) {
        final r = envJson[m.name];
        if (r is Map) env[m] = Reading.fromJson(r.cast<String, Object?>());
      }
    }

    final riskJson = j['risk'];
    final drivers = <Metric>[];
    var level = RiskLevel.good;
    var alertIds = <String>[];
    if (riskJson is Map) {
      level = RiskLevel.parse(riskJson['level']);
      final d = riskJson['drivers'];
      if (d is List) {
        for (final x in d) {
          final m = Metric.tryParse(x);
          if (m != null) drivers.add(m);
        }
      }
      final a = riskJson['active_alert_ids'];
      if (a is List) alertIds = a.whereType<String>().toList();
    }

    final presenceJson = j['presence'];
    final deviceJson = j['device'];
    final linksJson = j['links'];

    return Telemetry(
      deviceId: j['device_id'] as String? ?? '',
      seq: (j['seq'] as num?)?.toInt() ?? 0,
      uptimeS: (j['uptime_s'] as num?)?.toInt() ?? 0,
      at: (j['at'] as num?)?.toInt(),
      presence: presenceJson is Map
          ? Presence.fromJson(presenceJson.cast<String, Object?>())
          : Presence.empty,
      env: env,
      riskLevel: level,
      riskDrivers: drivers,
      activeAlertIds: alertIds,
      device: deviceJson is Map
          ? DeviceInfo.fromJson(deviceJson.cast<String, Object?>())
          : const DeviceInfo(fwVersion: '未知'),
      links: linksJson is Map ? Links.fromJson(linksJson.cast<String, Object?>()) : Links.unknown,
    );
  }

  /// 把 Delta（只含变化字段）合并进当前快照。
  ///
  /// 契约 §5：设备推送的增量只带变化的部分，
  /// **UI 永远只面对完整对象**，合并是 Channel 层的责任。
  Telemetry mergeDelta(Map<String, Object?> delta) {
    final mergedEnv = Map<Metric, Reading>.from(env);
    final envJson = delta['env'];
    if (envJson is Map) {
      for (final m in Metric.values) {
        final r = envJson[m.name];
        if (r is Map) mergedEnv[m] = Reading.fromJson(r.cast<String, Object?>());
      }
    }

    final presenceJson = delta['presence'];
    final riskJson = delta['risk'];
    final linksJson = delta['links'];

    return Telemetry(
      deviceId: delta['device_id'] as String? ?? deviceId,
      seq: (delta['seq'] as num?)?.toInt() ?? seq,
      uptimeS: (delta['uptime_s'] as num?)?.toInt() ?? uptimeS,
      at: (delta['at'] as num?)?.toInt() ?? at,
      presence: presenceJson is Map
          ? Presence.fromJson(presenceJson.cast<String, Object?>())
          : presence,
      env: mergedEnv,
      riskLevel: riskJson is Map ? RiskLevel.parse(riskJson['level']) : riskLevel,
      riskDrivers: riskJson is Map
          ? ((riskJson['drivers'] as List?)?.map(Metric.tryParse).whereType<Metric>().toList() ??
                riskDrivers)
          : riskDrivers,
      activeAlertIds: riskJson is Map
          ? ((riskJson['active_alert_ids'] as List?)?.whereType<String>().toList() ??
                activeAlertIds)
          : activeAlertIds,
      device: device,
      links: linksJson is Map ? Links.fromJson(linksJson.cast<String, Object?>()) : links,
    );
  }
}

/// 告警。
class Alert {
  const Alert({
    required this.id,
    required this.ruleId,
    required this.deviceId,
    required this.metric,
    required this.level,
    required this.value,
    required this.isActive,
    required this.raisedAt,
    this.unit = '',
    this.message = '',
    this.clearedAt,
  });

  final String id;
  final String ruleId;
  final String deviceId;
  final Metric metric;
  final RiskLevel level;
  final double value;
  final String unit;
  final String message;
  final bool isActive;
  final int raisedAt;
  final int? clearedAt;

  static Alert? tryParse(Map<String, Object?> j) {
    final metric = Metric.tryParse(j['metric']);
    final id = j['id'];
    if (metric == null || id is! String) return null;
    return Alert(
      id: id,
      ruleId: j['rule_id'] as String? ?? '',
      deviceId: j['device_id'] as String? ?? '',
      metric: metric,
      level: RiskLevel.parse(j['level']),
      value: (j['value'] as num?)?.toDouble() ?? 0,
      unit: j['unit'] as String? ?? '',
      message: j['message'] as String? ?? '',
      isActive: j['state'] == 'active',
      raisedAt: (j['raised_at'] as num?)?.toInt() ?? 0,
      clearedAt: (j['cleared_at'] as num?)?.toInt(),
    );
  }
}
