/// 契约解析与展示逻辑的单测。
///
/// 这两块是「编译通过 ≠ 逻辑对」的部分：
/// 设备发来的 JSON 是不可信输入，而展示逻辑决定了用户能不能
/// 分辨「传感器坏了」和「数值正常」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mmradar_app/core/contracts/rule.dart';
import 'package:mmradar_app/core/contracts/telemetry.dart';
import 'package:mmradar_app/core/format.dart';

Map<String, Object?> snapshotJson({
  Map<String, Object?>? co2,
  String presenceState = 'present_still',
  String riskLevel = 'fair',
  List<String> drivers = const ['co2'],
  int seq = 1,
}) => {
  'schema_version': 1,
  'device_id': 'mmr-a00000000001',
  'seq': seq,
  'uptime_s': 100,
  'at': 1700000000,
  'presence': {
    'state': presenceState,
    'distance_cm': 68,
    'in_zone': true,
    'state_since_at': 1700000000,
    'seated_duration_s': 3720,
    'health': 'ok',
  },
  'env': {
    'co2': co2 ?? {'value': 900, 'unit': 'ppm', 'level': 'fair', 'health': 'ok'},
    'temperature': {'value': 24.85, 'unit': 'c', 'level': 'good', 'health': 'ok'},
    'humidity': {'value': 50, 'unit': 'pct', 'level': 'good', 'health': 'ok'},
    'noise': {'value': 48, 'unit': 'dba', 'level': 'good', 'health': 'degraded'},
    'lux': {'value': null, 'unit': 'lux', 'level': 'good', 'health': 'absent'},
  },
  'risk': {'level': riskLevel, 'drivers': drivers, 'active_alert_ids': <String>[]},
  'device': {
    'fw_version': '0.2.0',
    'rssi_dbm': -52,
    'wifi_ssid': 'home',
    'battery_pct': null,
    'is_charging': null,
    'free_heap_bytes': 260932,
  },
  'links': {'cloud': 'connected', 'mqtt': 'disabled', 'local': 'connected'},
};

void main() {
  group('契约解析', () {
    test('解析完整快照', () {
      final t = Telemetry.fromJson(snapshotJson());
      expect(t.deviceId, 'mmr-a00000000001');
      expect(t.seq, 1);
      expect(t.presence.state, PresenceState.presentStill);
      expect(t.presence.isPresent, isTrue);
      expect(t.riskLevel, RiskLevel.fair);
      expect(t.riskDrivers, [Metric.co2]);
      expect(t.reading(Metric.co2).value, 900);
    });

    test('null 值不被当成 0', () {
      final t = Telemetry.fromJson(snapshotJson());
      // 契约要求缺失用 null。若解析成 0，UI 会显示「0 lx」这种假数据
      expect(t.reading(Metric.lux).value, isNull);
      expect(t.reading(Metric.lux).usable, isFalse);
    });

    test('degraded 的读数仍然可用', () {
      final t = Telemetry.fromJson(snapshotJson());
      // 有偏差的数好过没有数，UI 会另行标注
      expect(t.reading(Metric.noise).usable, isTrue);
      expect(t.reading(Metric.noise).health, SensorHealth.degraded);
    });

    test('未知枚举值降级而不是抛异常', () {
      // 设备固件可能比 App 新，多出来的枚举值不该让整个界面白屏
      final t = Telemetry.fromJson(
        snapshotJson(riskLevel: 'catastrophic', drivers: ['pm25', 'co2']),
      );
      expect(t.riskLevel, RiskLevel.good);
      expect(t.riskDrivers, [Metric.co2]); // 未知的 pm25 被丢弃，已知的保留
    });

    test('缺字段的 JSON 不崩溃', () {
      final t = Telemetry.fromJson({'device_id': 'mmr-000000000000'});
      expect(t.seq, 0);
      expect(t.presence.state, PresenceState.absent);
      expect(t.reading(Metric.co2).health, SensorHealth.absent);
    });

    test('battery_pct 恒为 null（底板读不到电量）', () {
      final t = Telemetry.fromJson(snapshotJson());
      expect(t.device.batteryPct, isNull);
    });
  });

  group('Delta 合并', () {
    test('只更新变化的字段', () {
      final base = Telemetry.fromJson(snapshotJson());
      final merged = base.mergeDelta({
        'seq': 2,
        'env': {
          'co2': {'value': 1320, 'unit': 'ppm', 'level': 'poor', 'health': 'ok'},
        },
      });

      expect(merged.seq, 2);
      expect(merged.reading(Metric.co2).value, 1320);
      // 未出现在 delta 里的字段保持原值
      expect(merged.reading(Metric.temperature).value, 24.85);
      expect(merged.presence.seatedDurationS, 3720);
    });

    test('合并后 risk 也随之更新', () {
      final base = Telemetry.fromJson(snapshotJson());
      final merged = base.mergeDelta({
        'seq': 2,
        'risk': {
          'level': 'bad',
          'drivers': ['co2', 'noise'],
          'active_alert_ids': ['a1'],
        },
      });
      expect(merged.riskLevel, RiskLevel.bad);
      expect(merged.riskDrivers, [Metric.co2, Metric.noise]);
      expect(merged.hasActiveAlert, isTrue);
    });
  });

  group('展示逻辑', () {
    test('正常读数带单位', () {
      final t = Telemetry.fromJson(snapshotJson());
      expect(formatReading(t.reading(Metric.co2), Metric.co2).text, '900 ppm');
    });

    test('只有温度保留一位小数', () {
      final t = Telemetry.fromJson(snapshotJson());
      expect(formatReading(t.reading(Metric.temperature), Metric.temperature).text, '24.9 °C');
      expect(formatReading(t.reading(Metric.humidity), Metric.humidity).text, '50 %');
    });

    test('预热中显示状态而非数值', () {
      final t = Telemetry.fromJson(
        snapshotJson(co2: {'value': null, 'unit': 'ppm', 'level': 'good', 'health': 'warming_up'}),
      );
      final d = formatReading(t.reading(Metric.co2), Metric.co2);
      expect(d.text, '预热中');
      expect(d.isPlaceholder, isTrue);
    });

    test('故障显示故障，不显示陈旧值', () {
      // 关键：即使 value 还有数，health=fault 也必须显示「故障」。
      // 继续显示上一个有效值是最危险的做法。
      final t = Telemetry.fromJson(
        snapshotJson(co2: {'value': 1320, 'unit': 'ppm', 'level': 'poor', 'health': 'fault'}),
      );
      final d = formatReading(t.reading(Metric.co2), Metric.co2);
      expect(d.text, '故障');
      expect(d.isPlaceholder, isTrue);
    });

    test('未接入显示占位符', () {
      final t = Telemetry.fromJson(snapshotJson());
      final d = formatReading(t.reading(Metric.lux), Metric.lux);
      expect(d.text, '—');
      expect(d.note, '未接入');
    });

    test('degraded 显示数值但附精度提示', () {
      final t = Telemetry.fromJson(snapshotJson());
      final d = formatReading(t.reading(Metric.noise), Metric.noise);
      expect(d.text, '48 dBA');
      expect(d.isPlaceholder, isFalse);
      expect(d.note, contains('未标定'));
    });

    test('建议文案按可行动性排序：CO2 优先', () {
      expect(riskHint(RiskLevel.poor, [Metric.noise, Metric.co2]), contains('开窗'));
      expect(riskHint(RiskLevel.good, []), '环境良好');
    });

    test('四档配色互不相同', () {
      final colors = RiskLevel.values.map(riskColorValue).toSet();
      expect(colors.length, 4);
    });

    test('在座时长的人话表达', () {
      expect(formatSeated(30), '刚落座');
      expect(formatSeated(600), '已在座 10 分钟');
      expect(formatSeated(3720), '已在座 1 小时 2 分');
    });

    test('无距离时不显示 0', () {
      expect(formatDistance(null), '—');
      expect(formatDistance(68), '68 cm');
    });
  });

  group('规则', () {
    test('往返序列化保持字段', () {
      final json = {
        'id': 'rule_co2_high',
        'name': 'CO2 too high',
        'is_enabled': true,
        'metric': 'co2',
        'op': 'gt',
        'threshold': 1200,
        'threshold_high': null,
        'duration_s': 300,
        'hysteresis': 100,
        'requires_presence': true,
        'severity': 'poor',
        'cooldown_s': 1800,
        'actions': [
          {
            'type': 'screen',
            'config': {'text': 'Air is stale - open a window'},
          },
        ],
      };

      final rule = Rule.fromJson(json);
      expect(rule.metric, Metric.co2);
      expect(rule.durationS, 300);
      expect(rule.requiresPresence, isTrue);
      expect(rule.actions.single.type, ActionType.screen);

      final back = rule.toJson();
      expect(back['metric'], 'co2');
      expect(back['requires_presence'], true);
      // 枚举必须序列化回 snake_case 的线格式
      expect((back['actions']! as List).first, containsPair('type', 'screen'));
    });

    test('ha_service 的线格式是下划线', () {
      final a = RuleAction.fromJson({'type': 'ha_service', 'config': <String, Object?>{}});
      expect(a.type, ActionType.haService);
      expect(a.toJson()['type'], 'ha_service');
    });

    test('凭证不出现在 action config 里 —— 只有 channel_ref', () {
      final a = RuleAction.fromJson({
        'type': 'telegram',
        'config': {'channel_ref': 'tg_main'},
      });
      expect(a.channelRef, 'tg_main');
      expect(a.config.containsKey('bot_token'), isFalse);
    });
  });
}
