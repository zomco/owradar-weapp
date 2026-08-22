/// 日报设置。
///
/// 服务端每天在**用户本地**的指定时刻推一份昨天的回顾。
/// 时区必须由用户确认而不是由服务端猜 —— 猜错的后果是
/// 每天在凌晨收到一份关于昨天工位的报告。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/async_view.dart';
import '../../data/cloud_api.dart';
import '../../data/providers.dart';

class ReportSettingsPage extends ConsumerWidget {
  const ReportSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('日报')),
      body: asyncView(
        ref.watch(accountProvider),
        error: (e) => _Error(
          message: '$e',
          onRetry: () => ref.invalidate(accountProvider),
        ),
        data: (account) => _Body(account: account),
      ),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.account});
  final AccountInfo account;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  bool _busy = false;

  Future<void> _save({bool? enabled, int? tzOffsetMin, int? hour}) async {
    final api = ref.read(cloudApiProvider);
    if (api == null) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await api.updateReportPrefs(enabled: enabled, tzOffsetMin: tzOffsetMin, hour: hour);
      ref.invalidate(accountProvider);
    } on CloudException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.error.display)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final theme = Theme.of(context);

    if (!a.dailyReportAllowed) {
      // 套餐不含日报时不显示一堆点不动的控件 —— 说清楚原因就够了。
      // 「能不能用」由服务端返回的配额决定，客户端不自己判断套餐名。
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.summarize_outlined, size: 48),
              const SizedBox(height: 12),
              Text('日报是付费版功能', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                '每天早上收到一份昨天的回顾：坐了多久、空气怎么样、触发过哪些提醒。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      children: [
        SwitchListTile(
          value: a.reportEnabled,
          onChanged: _busy ? null : (v) => _save(enabled: v),
          title: const Text('每天发一份回顾'),
          subtitle: const Text('内容是前一天的在座时长、空气与提醒次数'),
        ),
        const Divider(height: 1),

        ListTile(
          enabled: a.reportEnabled && !_busy,
          leading: const Icon(Icons.schedule),
          title: const Text('发送时刻'),
          subtitle: Text('每天 ${a.reportHour.toString().padLeft(2, '0')}:00（你所在时区）'),
          trailing: const Icon(Icons.chevron_right),
          onTap: a.reportEnabled && !_busy ? () => _pickHour(a.reportHour) : null,
        ),

        ListTile(
          enabled: a.reportEnabled && !_busy,
          leading: const Icon(Icons.public),
          title: const Text('时区'),
          subtitle: Text(_tzLabel(a.tzOffsetMin)),
          trailing: const Icon(Icons.chevron_right),
          onTap: a.reportEnabled && !_busy ? () => _pickTimezone(a.tzOffsetMin) : null,
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(
            '时区决定日报在你本地的几点送达。设错的话，一份关于昨天工位的回顾'
            '可能在凌晨把你吵醒。',
            style: theme.textTheme.bodySmall,
          ),
        ),

        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }

  Future<void> _pickHour(int current) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('每天几点发'),
        children: [
          for (final h in const [6, 7, 8, 9, 10, 12, 18, 20, 21, 22])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, h),
              child: Row(
                children: [
                  Expanded(child: Text('${h.toString().padLeft(2, '0')}:00')),
                  if (h == current) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null && picked != current) await _save(hour: picked);
  }

  Future<void> _pickTimezone(int current) async {
    // 只列常见时区。完整列表有几十项，而这个设置一个用户一辈子改一次 ——
    // 「用本机时区」那一项已经覆盖绝大多数情况。
    final deviceOffset = DateTime.now().timeZoneOffset.inMinutes;
    final options = <int>{deviceOffset, 0, -480, -300, 60, 330, 480, 540}.toList()..sort();

    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('时区'),
        children: [
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, o),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      o == deviceOffset ? '${_tzLabel(o)}（本机）' : _tzLabel(o),
                    ),
                  ),
                  if (o == current) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null && picked != current) await _save(tzOffsetMin: picked);
  }
}

/// 把分钟偏移写成 UTC+8:00 这样。
///
/// 用分钟而不是小时是因为有 +5:30（印度）、+5:45（尼泊尔）这类时区 ——
/// 按整小时处理会让那些用户永远收不到对时候的日报。
String _tzLabel(int offsetMinutes) {
  final sign = offsetMinutes < 0 ? '-' : '+';
  final abs = offsetMinutes.abs();
  final h = abs ~/ 60;
  final m = abs % 60;
  return 'UTC$sign$h:${m.toString().padLeft(2, '0')}';
}

class _Error extends StatelessWidget {
  const _Error({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 44),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(message, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
