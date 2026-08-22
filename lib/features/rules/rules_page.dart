/// 规则配置。
///
/// **模板优先**：用户从预置模板挑一个、调个阈值就完事，
/// 不必面对「持续时长」「滞回」「冷却期」这些陌生概念。
/// 高级参数折叠在下面，需要的人才展开。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/async_view.dart';
import '../../core/contracts/command.dart';
import '../../core/contracts/rule.dart';
import '../../core/format.dart';
import '../../core/rule_templates.dart';
import '../../data/device_channel.dart';
import '../../data/providers.dart';

class RulesPage extends ConsumerWidget {
  const RulesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(rulesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('提醒规则')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openTemplatePicker(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('添加提醒'),
      ),
      body: asyncView(
        rules,
        error: (e) => _RulesError(message: '$e', onRetry: () => ref.invalidate(rulesProvider)),
        data: (list) => list.isEmpty
            ? _EmptyRules(onAdd: () => _openTemplatePicker(context, ref))
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _RuleCard(rule: list[i]),
              ),
      ),
    );
  }

  Future<void> _openTemplatePicker(BuildContext context, WidgetRef ref) async {
    final existing = ref.read(rulesProvider).value ?? const <Rule>[];
    final takenIds = existing.map((r) => r.id).toSet();

    final template = await showModalBottomSheet<RuleTemplate>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _TemplateSheet(takenIds: takenIds),
    );
    if (template == null || !context.mounted) return;

    await _editAndSave(context, ref, template.toRule(), template: template, isNew: true);
  }
}

/// 模板选择弹层。
class _TemplateSheet extends StatelessWidget {
  const _TemplateSheet({required this.takenIds});

  final Set<String> takenIds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text('选一个提醒', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('阈值、判定时长都已按常见场景预设好，添加后还能改', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          for (final t in kRuleTemplates)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                // 已经添加过的模板置灰，避免重复添加同 id 的规则
                enabled: !takenIds.contains(t.id),
                title: Text(t.title),
                subtitle: Text(takenIds.contains(t.id) ? '已添加' : t.description),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pop(t),
              ),
            ),
        ],
      ),
    );
  }
}

class _RuleCard extends ConsumerWidget {
  const _RuleCard({required this.rule});

  final Rule rule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color = Color(0xFF000000 | riskColorValue(rule.severity));

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 4,
              height: 42,
              margin: const EdgeInsets.only(right: 12, top: 2),
              decoration: BoxDecoration(
                color: rule.isEnabled ? color : theme.disabledColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rule.name.isNotEmpty ? rule.name : metricLabel(rule.metric),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: rule.isEnabled ? null : theme.disabledColor,
                    ),
                  ),
                  const SizedBox(height: 3),
                  // 一句人话，而不是 "co2 gt 1200 duration 300"
                  Text(describeRule(rule), style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            Switch(value: rule.isEnabled, onChanged: (v) => _toggle(context, ref, rule, v)),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'edit') {
                  await _editAndSave(
                    context,
                    ref,
                    rule,
                    template: templateFor(rule.id),
                    isNew: false,
                  );
                } else if (v == 'delete') {
                  await _delete(context, ref, rule);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('修改')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── 操作 ──────────────────────────────────────────────────

Future<void> _toggle(BuildContext context, WidgetRef ref, Rule rule, bool enabled) async {
  final result = await ref.read(channelProvider).setRule(rule.copyWith(isEnabled: enabled));
  if (!context.mounted) return;
  _reportAndRefresh(context, ref, result, okMessage: enabled ? '已启用' : '已停用');
}

Future<void> _delete(BuildContext context, WidgetRef ref, Rule rule) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('删除这条提醒？'),
      content: Text(describeRule(rule)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  final result = await ref.read(channelProvider).deleteRule(rule.id);
  if (!context.mounted) return;
  _reportAndRefresh(context, ref, result, okMessage: '已删除');
}

Future<void> _editAndSave(
  BuildContext context,
  WidgetRef ref,
  Rule rule, {
  RuleTemplate? template,
  required bool isNew,
}) async {
  final edited = await showModalBottomSheet<Rule>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _RuleEditor(rule: rule, template: template),
  );
  if (edited == null || !context.mounted) return;

  final result = await ref.read(channelProvider).setRule(edited);
  if (!context.mounted) return;
  _reportAndRefresh(context, ref, result, okMessage: isNew ? '已添加' : '已保存');
}

/// 统一的结果反馈。
///
/// 失败时显示设备给的具体原因 —— 比如「设备不支持该操作」，
/// 比一句笼统的「保存失败」有用得多。
void _reportAndRefresh(
  BuildContext context,
  WidgetRef ref,
  CommandResult result, {
  required String okMessage,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();

  switch (result) {
    case CommandOk():
      messenger.showSnackBar(SnackBar(content: Text(okMessage)));
      ref.invalidate(rulesProvider);
    case CommandFailed(:final error):
      messenger.showSnackBar(
        SnackBar(
          content: Text(error.display),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
  }
}

// ── 编辑器 ────────────────────────────────────────────────

class _RuleEditor extends StatefulWidget {
  const _RuleEditor({required this.rule, this.template});

  final Rule rule;
  final RuleTemplate? template;

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late double _threshold = widget.rule.threshold;
  late bool _requiresPresence = widget.rule.requiresPresence;
  late int _durationS = widget.rule.durationS;
  bool _advanced = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = widget.template;
    final min = t?.thresholdMin ?? 0;
    final max = t?.thresholdMax ?? 100;
    final step = t?.thresholdStep ?? 1;
    final divisions = ((max - min) / step).round().clamp(1, 1000);

    final preview = widget.rule.copyWith(
      threshold: _threshold,
      requiresPresence: _requiresPresence,
      durationS: _durationS,
    );

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.rule.name.isNotEmpty ? widget.rule.name : metricLabel(widget.rule.metric),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            // 实时预览：改完滑块立刻看到「会变成什么样」
            Text(describeRule(preview), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 18),

            Row(
              children: [
                Text('阈值', style: theme.textTheme.labelLarge),
                const Spacer(),
                Text(
                  _threshold.toStringAsFixed(step < 1 ? 1 : 0),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            Slider(
              value: _threshold.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: (v) => setState(() => _threshold = v),
            ),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _requiresPresence,
              onChanged: (v) => setState(() => _requiresPresence = v),
              title: const Text('只在我在座时提醒'),
              // 这是本产品区别于普通空气检测仪的核心，值得解释清楚
              subtitle: const Text('关掉后，没人的时候也会提醒'),
            ),

            TextButton.icon(
              onPressed: () => setState(() => _advanced = !_advanced),
              icon: Icon(_advanced ? Icons.expand_less : Icons.expand_more),
              label: const Text('高级设置'),
            ),
            if (_advanced) ...[
              const SizedBox(height: 4),
              Text('判定时长', style: theme.textTheme.labelLarge),
              Text('条件要持续这么久才提醒。太短会被瞬时波动误触发。', style: theme.textTheme.bodySmall),
              Slider(
                value: _durationS.toDouble().clamp(0, 900),
                max: 900,
                divisions: 30,
                label: _durationS < 60 ? '$_durationS 秒' : '${_durationS ~/ 60} 分钟',
                onChanged: (v) => setState(() => _durationS = v.round()),
              ),
            ],

            const SizedBox(height: 12),
            Row(
              children: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.pop(context, preview),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── 空态与错误 ────────────────────────────────────────────

class _EmptyRules extends StatelessWidget {
  const _EmptyRules({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.notifications_none, size: 48),
          const SizedBox(height: 12),
          const Text('还没有提醒规则'),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              '设备会持续监测，但只有配了规则才会主动提醒你',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onAdd, child: const Text('添加提醒')),
        ],
      ),
    );
  }
}

class _RulesError extends StatelessWidget {
  const _RulesError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 44),
          const SizedBox(height: 10),
          const Text('读不到规则'),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
