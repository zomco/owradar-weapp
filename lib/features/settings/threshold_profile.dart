/// 分级标准：按地区选一套。
///
/// **用户选的是「我在哪」，不是「用哪套标准」。** 没人知道
/// EN 16798-1 和 GB/T 18883 有什么区别，但每个人都知道自己在欧洲还是中国。
/// 所以列表上写地区，标准名放在副标题里作为依据 —— 想深究的人看得到，
/// 不想深究的人不必懂。
///
/// 具体数值与来源见契约 §8.1。这里刻意**不复述那些数字**：
/// 复述一遍就多一处会与设备端不同步的地方，而设备端才是权威。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/async_view.dart';
import '../../core/contracts/command.dart';
import '../../data/device_channel.dart';
import '../../data/providers.dart';

/// 一个可选的地区档。
class ThresholdProfileOption {
  const ThresholdProfileOption({
    required this.id,
    required this.label,
    required this.basis,
  });

  /// 契约里的取值：`international` / `eu` / `china`。
  final String id;

  /// 给用户看的地区名。
  final String label;

  /// 依据的标准。放副标题，不放标题。
  final String basis;
}

const thresholdProfiles = <ThresholdProfileOption>[
  ThresholdProfileOption(
    id: 'international',
    label: '国际通用',
    basis: 'ASHRAE 55 / ASHRAE 62.1',
  ),
  ThresholdProfileOption(
    id: 'eu',
    label: '欧盟',
    basis: 'EN 16798-1 / EN 12464-1',
  ),
  ThresholdProfileOption(
    id: 'china',
    label: '中国',
    basis: 'GB/T 18883-2022 / GB 50736 / GB 50034',
  ),
];

class ThresholdProfilePage extends ConsumerWidget {
  const ThresholdProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('分级标准')),
      body: asyncView(
        ref.watch(thresholdProfileProvider),
        error: (e) => _Error(
          message: '$e',
          onRetry: () => ref.invalidate(thresholdProfileProvider),
        ),
        data: (current) => _Body(current: current),
      ),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.current});
  final String current;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  bool _busy = false;

  Future<void> _select(ThresholdProfileOption option) async {
    if (option.id == widget.current) return;

    // 换档会重置用户改过的阈值，所以先问一句。
    // 不问的话，一次误触就把用户调了半天的设置清掉了。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('切换到「${option.label}」？'),
        content: const Text(
          '五项指标的分级界线会整体重置为该地区标准的取值，'
          '你此前手动调整过的阈值会被覆盖。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('切换')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    setState(() => _busy = true);
    try {
      final result = await ref.read(channelProvider).setThresholdProfile(option.id);
      messenger.clearSnackBars();
      switch (result) {
        case CommandOk():
          messenger.showSnackBar(SnackBar(content: Text('已切换到「${option.label}」')));
          ref.invalidate(thresholdProfileProvider);
          // 分级变了，当前读数的颜色也跟着变 —— 让看板重新拉一次
          ref.invalidate(rulesProvider);
        case CommandFailed(:final error):
          messenger.showSnackBar(
            SnackBar(content: Text(error.display), backgroundColor: errorColor),
          );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            '空气质量与舒适区的界线由各地标准规定，没有一套放之四海皆准的数。'
            '选你所在的地区即可。',
            style: theme.textTheme.bodyMedium,
          ),
        ),

        // RadioGroup 而不是给每个 RadioListTile 传 groupValue/onChanged ——
        // 后两者在当前 Flutter 版本已弃用。
        RadioGroup<String>(
          groupValue: widget.current,
          // RadioGroup 的 onChanged 不接受 null，所以在回调里判 busy，
          // 而不是把整个回调置空
          onChanged: (id) {
            if (_busy || id == null) return;
            _select(thresholdProfiles.firstWhere((o) => o.id == id));
          },
          child: Column(
            children: [
              for (final option in thresholdProfiles)
                RadioListTile<String>(
                  key: Key('profile-${option.id}'),
                  value: option.id,
                  title: Text(option.label),
                  subtitle: Text(option.basis, style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            '噪音的分级在各地区相同 —— 各国的噪音标准针对的是听力损伤或社区噪音，'
            '没有专门针对工位舒适度的地区差异。',
            style: theme.textTheme.bodySmall,
          ),
        ),

        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }
}

class _Error extends StatelessWidget {
  const _Error({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
