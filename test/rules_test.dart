/// 规则模板与规则界面。
///
/// 模板的意义是「让告警不烦人」——
/// 去抖、滞回、冷却期这三项如果留给用户填，多半会填出一个
/// 每分钟弹一次的规则。所以模板必须预设，且必须有测试守住。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmradar_app/core/contracts/rule.dart';
import 'package:mmradar_app/core/contracts/telemetry.dart';
import 'package:mmradar_app/core/rule_templates.dart';
import 'package:mmradar_app/data/providers.dart';
import 'package:mmradar_app/features/rules/rules_page.dart';

Rule _rule({
  String id = 'rule_co2_high',
  Metric metric = Metric.co2,
  RuleOp op = RuleOp.gt,
  double threshold = 1200,
  int durationS = 300,
  bool requiresPresence = true,
  bool isEnabled = true,
  String name = 'CO₂ 超标提醒',
}) => Rule(
  id: id,
  name: name,
  metric: metric,
  op: op,
  threshold: threshold,
  durationS: durationS,
  requiresPresence: requiresPresence,
  isEnabled: isEnabled,
  severity: RiskLevel.poor,
  actions: const [
    RuleAction(type: ActionType.screen, config: {'text': '开窗通风'}),
  ],
);

Future<void> _pumpRules(WidgetTester tester, List<Rule> rules) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [rulesProvider.overrideWith((ref) async => rules)],
      child: const MaterialApp(home: RulesPage()),
    ),
  );
  await _settle(tester);
}

/// FutureProvider 的成功与失败落在不同的微任务轮次上，多 pump 几帧。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

void main() {
  group('模板', () {
    test('id 唯一 —— 重复会让设备端覆盖掉上一条规则', () {
      final ids = kRuleTemplates.map((t) => t.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('每个模板都设了去抖与冷却，不会连珠炮式告警', () {
      for (final t in kRuleTemplates) {
        expect(t.durationS, greaterThan(0), reason: '${t.id} 缺去抖');
        expect(t.cooldownS, greaterThanOrEqualTo(t.durationS), reason: '${t.id} 冷却期太短');
        expect(t.hysteresis, greaterThan(0), reason: '${t.id} 缺滞回');
      }
    });

    test('默认阈值落在可调范围内', () {
      for (final t in kRuleTemplates) {
        expect(t.defaultThreshold, greaterThanOrEqualTo(t.thresholdMin), reason: t.id);
        expect(t.defaultThreshold, lessThanOrEqualTo(t.thresholdMax), reason: t.id);
      }
    });

    test('toRule 生成的规则带屏幕动作 —— 断网也要有反馈', () {
      for (final t in kRuleTemplates) {
        final r = t.toRule();
        expect(r.actions.any((a) => a.type == ActionType.screen), isTrue, reason: t.id);
        expect(r.id, t.id);
      }
    });

    test('toRule 可覆盖阈值，其余参数保持模板值', () {
      final t = templateFor('rule_co2_high')!;
      final r = t.toRule(threshold: 900);

      expect(r.threshold, 900);
      expect(r.durationS, t.durationS);
      expect(r.hysteresis, t.hysteresis);
      expect(r.cooldownS, t.cooldownS);
    });

    test('模板序列化后仍满足契约字段名', () {
      final j = templateFor('rule_noise_high')!.toRule().toJson();

      expect(j['metric'], 'noise');
      expect(j['op'], 'gt');
      expect(j['duration_s'], isA<int>());
      expect(j['requires_presence'], isTrue);
      expect((j['actions'] as List).first, containsPair('type', 'screen'));
    });

    test('未知 id 返回 null 而不是抛异常', () {
      expect(templateFor('rule_does_not_exist'), isNull);
    });
  });

  group('规则描述', () {
    test('说人话：在座、阈值、持续时长', () {
      expect(describeRule(_rule()), '你在座时，二氧化碳超过 1200 ppm 持续 5 分钟就提醒');
    });

    test('不要求在座时不加前缀', () {
      final s = describeRule(_rule(requiresPresence: false));
      expect(s.startsWith('二氧化碳'), isTrue);
    });

    test('小于号读作「低于」', () {
      final s = describeRule(
        _rule(
          id: 'rule_lux_low',
          metric: Metric.lux,
          op: RuleOp.lt,
          threshold: 200,
          durationS: 300,
        ),
      );
      expect(s, contains('光照低于 200 lx'));
    });

    test('不足一分钟的去抖按秒说', () {
      final s = describeRule(_rule(durationS: 30));
      expect(s, contains('持续 30 秒'));
    });

    test('无去抖时不出现「持续」', () {
      final s = describeRule(_rule(durationS: 0));
      expect(s, isNot(contains('持续')));
    });

    test('温度这类小数阈值保留一位', () {
      final s = describeRule(_rule(metric: Metric.temperature, threshold: 28.5));
      expect(s, contains('28.5°C'));
    });
  });

  group('规则界面', () {
    testWidgets('列出规则并渲染成人话', (tester) async {
      await _pumpRules(tester, [_rule()]);

      expect(find.text('CO₂ 超标提醒'), findsOneWidget);
      expect(find.textContaining('二氧化碳超过 1200 ppm'), findsOneWidget);
    });

    testWidgets('没有规则时引导添加，而不是空白页', (tester) async {
      await _pumpRules(tester, []);

      expect(find.textContaining('还没有'), findsOneWidget);
      expect(find.text('添加提醒'), findsWidgets);
    });

    testWidgets('停用的规则要看得出来是停用的', (tester) async {
      await _pumpRules(tester, [_rule(isEnabled: false)]);

      final sw = tester.widget<Switch>(find.byType(Switch).first);
      expect(sw.value, isFalse);
    });

    testWidgets('读取失败时给重试，而不是永远转圈', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [rulesProvider.overrideWith((ref) async => throw Exception('设备离线'))],
          child: const MaterialApp(home: RulesPage()),
        ),
      );
      await _settle(tester);

      expect(find.textContaining('设备离线'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('模板选择器列出全部模板', (tester) async {
      await _pumpRules(tester, []);

      await tester.tap(find.text('添加提醒').first);
      await tester.pumpAndSettle();

      for (final t in kRuleTemplates) {
        expect(find.text(t.title), findsOneWidget, reason: t.id);
      }
    });

    testWidgets('已存在的模板不能重复添加 —— 同 id 会互相覆盖', (tester) async {
      await _pumpRules(tester, [_rule(id: 'rule_co2_high')]);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text(templateFor('rule_co2_high')!.title),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.enabled, isFalse);
    });
  });
}
