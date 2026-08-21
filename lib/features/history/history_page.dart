/// 历史曲线。
///
/// 数据是**分钟级聚合**，没有原始秒级 —— 见服务端架构 §4。
/// 只有云模式才有历史：局域网直连时设备本身不存历史
/// （固件明确不落 Flash，见固件架构 §6）。
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/async_view.dart';
import '../../core/contracts/telemetry.dart';
import '../../core/format.dart';
import '../../data/cloud_api.dart';
import '../../data/providers.dart';

/// 可查看的时间跨度。
enum HistoryRange {
  hour(3600, '1 小时'),
  sixHours(6 * 3600, '6 小时'),
  day(24 * 3600, '24 小时'),
  week(7 * 24 * 3600, '7 天');

  const HistoryRange(this.seconds, this.label);
  final int seconds;
  final String label;
}

class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cloud = ref.watch(cloudApiProvider);
    final span = ref.watch(historySpanProvider);
    final metric = ref.watch(historyMetricProvider);
    final range = HistoryRange.values.firstWhere(
      (r) => r.seconds == span,
      orElse: () => HistoryRange.hour,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('历史'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: _RangeSelector(
            value: range,
            onChanged: (r) => ref.read(historySpanProvider.notifier).set(r.seconds),
          ),
        ),
      ),
      body: cloud == null
          ? const _CloudRequired()
          : asyncView(
              ref.watch(historyProvider),
              error: (e) =>
                  _HistoryError(message: '$e', onRetry: () => ref.invalidate(historyProvider)),
              data: (result) => _HistoryBody(
                result: result,
                metric: metric,
                onMetricChanged: (m) => ref.read(historyMetricProvider.notifier).set(m),
              ),
            ),
    );
  }
}

class _HistoryBody extends StatelessWidget {
  const _HistoryBody({required this.result, required this.metric, required this.onMetricChanged});

  final HistoryResult result;
  final Metric metric;
  final ValueChanged<Metric> onMetricChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final series = _series(result.points, metric);

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 16, 24),
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final m in Metric.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(metricLabel(m)),
                    selected: m == metric,
                    onSelected: (_) => onMetricChanged(m),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        if (result.truncated)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: _Notice(
              // 裁剪而非报错：用户拖时间轴超出保留期是很自然的操作，
              // 但必须告诉他为什么前面是空的
              text: '免费版保留 7 天历史，更早的数据已不可见',
              icon: Icons.info_outline,
            ),
          ),

        if (series.isEmpty)
          const _Notice(text: '这段时间没有数据。设备离线或还没运行这么久。', icon: Icons.timeline)
        else
          SizedBox(
            height: 260,
            child: Padding(
              padding: const EdgeInsets.only(right: 8, top: 8),
              child: LineChart(_chartData(context, series, metric)),
            ),
          ),

        const SizedBox(height: 20),
        _Summary(points: result.points, metric: metric, theme: theme),
      ],
    );
  }

  /// 抽出某个指标的时间序列，跳过没有数据的桶。
  ///
  /// 缺口不做插值 —— 设备离线那段就该是断的，
  /// 连成直线会让人以为期间一切正常。
  static List<FlSpot> _series(List<HistoryPoint> points, Metric metric) {
    final out = <FlSpot>[];
    for (final p in points) {
      final v = switch (metric) {
        Metric.co2 => p.co2Avg,
        Metric.temperature => p.temperatureAvg,
        Metric.humidity => p.humidityAvg,
        Metric.noise => p.noiseAvg,
        Metric.lux => p.luxAvg,
      };
      if (v == null) continue;
      out.add(FlSpot(p.bucketAt.toDouble(), v));
    }
    return out;
  }

  LineChartData _chartData(BuildContext context, List<FlSpot> spots, Metric metric) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;

    final xs = spots.map((s) => s.x);
    final ys = spots.map((s) => s.y);
    final minY = ys.reduce((a, b) => a < b ? a : b);
    final maxY = ys.reduce((a, b) => a > b ? a : b);
    // 上下留 10% 余量，曲线贴边不好看也不好读
    final pad = ((maxY - minY).abs() * 0.1).clamp(1.0, double.infinity);

    return LineChartData(
      minX: xs.reduce((a, b) => a < b ? a : b),
      maxX: xs.reduce((a, b) => a > b ? a : b),
      minY: minY - pad,
      maxY: maxY + pad,
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        getDrawingHorizontalLine: (_) =>
            FlLine(color: theme.dividerColor.withValues(alpha: 0.4), strokeWidth: 1),
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 44,
            getTitlesWidget: (v, meta) => Text(
              v.toStringAsFixed(metric == Metric.temperature ? 1 : 0),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 28,
            interval: ((xs.last - xs.first) / 4).clamp(60, double.infinity),
            getTitlesWidget: (v, meta) {
              final t = DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000);
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                  style: theme.textTheme.bodySmall,
                ),
              );
            },
          ),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          curveSmoothness: 0.2,
          color: color,
          barWidth: 2,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: true, color: color.withValues(alpha: 0.12)),
        ),
      ],
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipItems: (touched) => touched.map((s) {
            final t = DateTime.fromMillisecondsSinceEpoch(s.x.toInt() * 1000);
            return LineTooltipItem(
              '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}\n'
              '${s.y.toStringAsFixed(metric == Metric.temperature ? 1 : 0)} ${unitLabel(metric)}',
              TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 12),
            );
          }).toList(),
        ),
      ),
    );
  }
}

/// 区间统计。曲线看趋势，这里给结论。
class _Summary extends StatelessWidget {
  const _Summary({required this.points, required this.metric, required this.theme});

  final List<HistoryPoint> points;
  final Metric metric;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();

    final seatedS = points.fold<int>(0, (a, p) => a + p.presenceS);
    final values = <double>[];
    for (final p in points) {
      final v = switch (metric) {
        Metric.co2 => p.co2Avg,
        Metric.temperature => p.temperatureAvg,
        Metric.humidity => p.humidityAvg,
        Metric.noise => p.noiseAvg,
        Metric.lux => p.luxAvg,
      };
      if (v != null) values.add(v);
    }

    final digits = metric == Metric.temperature ? 1 : 0;
    final unit = unitLabel(metric);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('区间统计', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 28,
              runSpacing: 12,
              children: [
                _Stat(label: '在座时长', value: seatedS < 60 ? '不足 1 分钟' : '${seatedS ~/ 60} 分钟'),
                if (values.isNotEmpty) ...[
                  _Stat(
                    label: '平均',
                    value:
                        '${(values.reduce((a, b) => a + b) / values.length).toStringAsFixed(digits)} $unit',
                  ),
                  _Stat(
                    label: '最高',
                    value:
                        '${values.reduce((a, b) => a > b ? a : b).toStringAsFixed(digits)} $unit',
                  ),
                  _Stat(
                    label: '最低',
                    value:
                        '${values.reduce((a, b) => a < b ? a : b).toStringAsFixed(digits)} $unit',
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _RangeSelector extends StatelessWidget {
  const _RangeSelector({required this.value, required this.onChanged});

  final HistoryRange value;
  final ValueChanged<HistoryRange> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: SegmentedButton<HistoryRange>(
        segments: [
          for (final r in HistoryRange.values) ButtonSegment(value: r, label: Text(r.label)),
        ],
        selected: {value},
        onSelectionChanged: (s) => onChanged(s.first),
        showSelectedIcon: false,
      ),
    );
  }
}

/// 局域网模式下没有历史 —— 设备本身不存。
class _CloudRequired extends StatelessWidget {
  const _CloudRequired();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Text('历史数据需要连接云端', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '设备本身不保存历史 —— 频繁写入会磨损存储。'
              '在设置里登录并开启云连接后，这里就能看到长期趋势。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.icon});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _HistoryError extends StatelessWidget {
  const _HistoryError({required this.message, required this.onRetry});

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
          const Text('读不到历史数据'),
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
