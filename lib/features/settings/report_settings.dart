/// 定期报告的设置：日报与周报。
///
/// 服务端在**用户本地**的指定时刻推送。时区必须由用户确认而不是
/// 由服务端猜 —— 猜错的后果是每天在凌晨收到一份关于昨天工位的报告。
///
/// 日报与周报是两个独立开关，共用同一个发送时刻和同一个配额位：
/// 它们回答不同的问题（昨天怎么样 / 这周比上周如何），
/// 绑一起的话想关周报的用户只能连日报一起关掉；
/// 而让用户为周报再设一遍「早上 8 点」纯属多余。
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
      appBar: AppBar(title: const Text('定期报告')),
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

  Future<void> _save({
    bool? enabled,
    bool? weeklyEnabled,
    int? tzOffsetMin,
    int? hour,
  }) async {
    final api = ref.read(cloudApiProvider);
    if (api == null) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await api.updateReportPrefs(
        enabled: enabled,
        weeklyEnabled: weeklyEnabled,
        tzOffsetMin: tzOffsetMin,
        hour: hour,
      );
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
              Text('定期报告是付费版功能', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                '日报是昨天的回顾：坐了多久、空气怎么样、触发过哪些提醒。\n'
                '周报只讲跨天才看得出的事：比上周多坐了多久、哪天空气最差。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }

    // 发送时刻与时区对两种报告都生效，所以任一开着就该能改。
    // 只看日报的话，只开周报的用户会发现时区是灰的、改不了。
    final anyEnabled = a.reportEnabled || a.weeklyReportEnabled;

    return ListView(
      children: [
        SwitchListTile(
          key: const Key('daily-report-switch'),
          value: a.reportEnabled,
          onChanged: _busy ? null : (v) => _save(enabled: v),
          title: const Text('每天发一份回顾'),
          subtitle: const Text('内容是前一天的在座时长、空气与提醒次数'),
        ),

        SwitchListTile(
          key: const Key('weekly-report-switch'),
          value: a.weeklyReportEnabled,
          onChanged: _busy ? null : (v) => _save(weeklyEnabled: v),
          title: const Text('每周一发一份总结'),
          // 说清楚它和日报不重复，否则用户会以为这只是「日报 ×7」
          subtitle: const Text('只讲跨天才看得出的事：比上周多坐了多久、哪天空气最差'),
        ),
        const Divider(height: 1),

        ListTile(
          enabled: anyEnabled && !_busy,
          leading: const Icon(Icons.schedule),
          title: const Text('发送时刻'),
          subtitle: Text('${a.reportHour.toString().padLeft(2, '0')}:00（你所在时区）'),
          trailing: const Icon(Icons.chevron_right),
          onTap: anyEnabled && !_busy ? () => _pickHour(a.reportHour) : null,
        ),

        ListTile(
          enabled: anyEnabled && !_busy,
          leading: const Icon(Icons.public),
          title: const Text('时区'),
          subtitle: Text(_tzLabel(a.tzOffsetMin)),
          trailing: const Icon(Icons.chevron_right),
          onTap: anyEnabled && !_busy ? () => _pickTimezone(a.tzOffsetMin) : null,
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(
            '时区决定报告在你本地的几点送达。设错的话，一份关于昨天工位的回顾'
            '可能在凌晨把你吵醒。周报固定在周一发。',
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
        title: const Text('几点发'),
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
