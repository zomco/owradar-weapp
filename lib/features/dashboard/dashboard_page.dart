/// 实时看板。
///
/// 主视觉是**整机风险等级**（大色块 + 一句人话），而不是五个并列的数字。
/// 用户要的是「现在要不要做点什么」，不是一堆读数。
/// 见 04-app-architecture.md §6.1。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/contracts/telemetry.dart';
import '../../core/format.dart';
import '../../data/device_channel.dart';
import '../../data/providers.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  @override
  Widget build(BuildContext context) {
    // 告警到达时弹一条横幅。监听放在 build 里是 Riverpod 的惯例做法。
    ref.listen(latestAlertProvider, (_, next) {
      final alert = next.value;
      if (alert == null || !alert.isActive || !mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(alert.message.isNotEmpty ? alert.message : metricLabel(alert.metric)),
            backgroundColor: Color(0xFF000000 | riskColorValue(alert.level)),
            duration: const Duration(seconds: 6),
          ),
        );
    });

    final telemetry = ref.watch(telemetryProvider);
    final status = ref.watch(channelStatusProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: Text(ref.watch(endpointProvider).name),
        actions: [
          _ConnectionChip(status: status),
          const SizedBox(width: 8),
        ],
      ),
      body: telemetry.when(
        loading: () => const _Centered(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorView(message: '$e', onRetry: () => ref.invalidate(channelProvider)),
        data: (t) => _DashboardBody(telemetry: t),
      ),
    );
  }
}

class _DashboardBody extends ConsumerWidget {
  const _DashboardBody({required this.telemetry});

  final Telemetry telemetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      onRefresh: () async => ref.read(channelProvider).getSnapshot(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _RiskBanner(telemetry: telemetry),
          const SizedBox(height: 16),
          _PresenceCard(presence: telemetry.presence),
          const SizedBox(height: 16),
          _MetricList(telemetry: telemetry),
          const SizedBox(height: 16),
          _DeviceFooter(telemetry: telemetry),
        ],
      ),
    );
  }
}

/// 风险横幅 —— 页面的主视觉。
class _RiskBanner extends StatelessWidget {
  const _RiskBanner({required this.telemetry});

  final Telemetry telemetry;

  @override
  Widget build(BuildContext context) {
    final color = Color(0xFF000000 | riskColorValue(telemetry.riskLevel));
    final absent = !telemetry.presence.isPresent;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        // 无人时整体压暗：产品承诺「没人的时候不打扰」，
        // 界面也该体现这一点，而不是一直亮着一块警示色。
        color: absent ? color.withValues(alpha: 0.35) : color,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                riskTitle(telemetry.riskLevel),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
              const Spacer(),
              if (telemetry.hasActiveAlert)
                const Icon(Icons.notifications_active, color: Colors.white),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            absent ? '无人在座 · 监测已暂停' : riskHint(telemetry.riskLevel, telemetry.riskDrivers),
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

class _PresenceCard extends StatelessWidget {
  const _PresenceCard({required this.presence});

  final Presence presence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final present = presence.isPresent;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              present ? Icons.event_seat : Icons.chair_outlined,
              size: 32,
              color: present ? theme.colorScheme.primary : theme.disabledColor,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(presenceLabel(presence.state), style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    present ? formatSeated(presence.seatedDurationS) : '离开中',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('距离', style: theme.textTheme.bodySmall),
                Text(
                  formatDistance(presence.distanceCm),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricList extends StatelessWidget {
  const _MetricList({required this.telemetry});

  final Telemetry telemetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (final m in Metric.values)
            _MetricRow(
              metric: m,
              reading: telemetry.reading(m),
              // 导致当前风险等级的指标高亮，其余保持常规色
              isDriver: telemetry.riskDrivers.contains(m),
              riskLevel: telemetry.riskLevel,
              isLast: m == Metric.values.last,
            ),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.metric,
    required this.reading,
    required this.isDriver,
    required this.riskLevel,
    required this.isLast,
  });

  final Metric metric;
  final Reading reading;
  final bool isDriver;
  final RiskLevel riskLevel;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = formatReading(reading, metric);

    final valueColor = display.isPlaceholder
        ? theme.disabledColor
        : isDriver
        ? Color(0xFF000000 | riskColorValue(riskLevel))
        : theme.colorScheme.onSurface;

    return Container(
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(metricLabel(metric), style: theme.textTheme.bodyLarge),
                if (display.note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      display.note,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                    ),
                  ),
              ],
            ),
          ),
          Text(
            display.text,
            style: theme.textTheme.titleMedium?.copyWith(
              color: valueColor,
              fontWeight: isDriver ? FontWeight.w700 : FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceFooter extends StatelessWidget {
  const _DeviceFooter({required this.telemetry});

  final Telemetry telemetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = telemetry.device;
    final rssi = d.rssiDbm;

    return DefaultTextStyle(
      style: theme.textTheme.bodySmall ?? const TextStyle(),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          Text('固件 ${d.fwVersion}'),
          Text('序号 ${telemetry.seq}'),
          if (d.wifiSsid != null) Text('Wi-Fi ${d.wifiSsid}'),
          if (rssi != null) Text('信号 $rssi dBm'),
          Text('局域网 ${linkLabel(telemetry.links.local)}'),
          Text('云 ${linkLabel(telemetry.links.cloud)}'),
        ],
      ),
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.status});

  final ChannelStatus? status;

  @override
  Widget build(BuildContext context) {
    final s = status?.state ?? ChannelState.idle;
    final (color, label) = switch (s) {
      ChannelState.connected => (Colors.green, '已连接'),
      ChannelState.connecting => (Colors.orange, '连接中'),
      ChannelState.reconnecting => (Colors.orange, '重连中'),
      ChannelState.failed => (Colors.red, '连接失败'),
      ChannelState.idle => (Colors.grey, '未连接'),
    };

    return Tooltip(
      message: status?.detail.isNotEmpty == true ? status!.detail : label,
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _Centered(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 48),
          const SizedBox(height: 12),
          const Text('连接不上设备'),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(child: child);
}
