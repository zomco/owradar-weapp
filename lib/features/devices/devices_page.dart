/// 设备列表与配对。
///
/// 配对码是**设备生成的**（屏幕上显示，10 分钟过期，一次性），
/// 不是云端下发的 —— 这样没有账号也能先把设备用起来，
/// 绑定只是把已经在跑的设备接到账号上。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/async_view.dart';
import '../../data/cloud_api.dart';
import '../../data/providers.dart';

class DevicesPage extends ConsumerWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(cloudDevicesProvider);
    final selectedId = ref.watch(sessionProvider).deviceId;

    return Scaffold(
      appBar: AppBar(title: const Text('我的设备')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _pairFlow(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('添加设备'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(cloudDevicesProvider),
        child: asyncView(
          devices,
          error: (e) =>
              _ErrorView(message: '$e', onRetry: () => ref.invalidate(cloudDevicesProvider)),
          data: (list) => list.isEmpty
              ? const _EmptyView()
              : ListView.separated(
                  // 必须能滚动，否则 RefreshIndicator 在只有一台设备时下拉不动
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) =>
                      _DeviceTile(device: list[i], selected: list[i].id == selectedId),
                ),
        ),
      ),
    );
  }

  Future<void> _pairFlow(BuildContext context, WidgetRef ref) async {
    // 在任何 await 之前拿到 messenger：await 之后这个 context 可能已经不在树上了
    final messenger = ScaffoldMessenger.of(context);
    final code = await showDialog<String>(context: context, builder: (_) => const _PairDialog());
    if (code == null || code.isEmpty) return;

    final api = ref.read(cloudApiProvider);
    if (api == null) return;

    try {
      final device = await api.pair(code);
      await ref.read(sessionProvider.notifier).selectDevice(device.id);
      ref.invalidate(cloudDevicesProvider);
      messenger.showSnackBar(SnackBar(content: Text('已绑定「${device.name}」')));
    } on CloudException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.error.display)));
    }
  }
}

class _DeviceTile extends ConsumerWidget {
  const _DeviceTile({required this.device, required this.selected});

  final CloudDevice device;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final online = device.looksOnline;

    return ListTile(
      leading: Badge(
        // 用小圆点而不是文字：列表里一眼扫过去比读「在线/离线」快
        backgroundColor: online ? Colors.green : theme.disabledColor,
        smallSize: 10,
        alignment: Alignment.bottomRight,
        child: const Icon(Icons.sensors, size: 28),
      ),
      title: Text(device.name),
      subtitle: Text(
        [
          device.model,
          if (device.fwVersion != null) 'v${device.fwVersion}',
          online ? '在线' : _lastSeenText(device.lastSeenAt),
        ].join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected)
            Icon(Icons.check_circle, color: theme.colorScheme.primary)
          else
            TextButton(
              onPressed: () async {
                await ref.read(sessionProvider.notifier).selectDevice(device.id);
                // 换设备就得换通道，否则还订阅着上一台的流
                ref.invalidate(channelProvider);
              },
              child: const Text('使用'),
            ),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'rename' => _rename(context, ref),
              'unpair' => _unpair(context, ref),
              _ => null,
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'unpair', child: Text('解绑')),
            ],
          ),
        ],
      ),
    );
  }

  static String _lastSeenText(int? at) {
    if (at == null) return '从未上线';
    final ago = DateTime.now().millisecondsSinceEpoch ~/ 1000 - at;
    if (ago < 3600) return '${ago ~/ 60} 分钟前';
    if (ago < 86400) return '${ago ~/ 3600} 小时前';
    return '${ago ~/ 86400} 天前';
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController(text: device.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '设备名称'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == device.name) return;

    final api = ref.read(cloudApiProvider);
    if (api == null) return;
    try {
      await api.rename(device.id, name);
      ref.invalidate(cloudDevicesProvider);
    } on CloudException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.error.display)));
    }
  }

  Future<void> _unpair(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('解绑「${device.name}」？'),
        content: const Text('设备会继续在本地工作，但不再上云，历史数据也会随保留期到期删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('解绑')),
        ],
      ),
    );
    if (!(ok ?? false)) return;

    final api = ref.read(cloudApiProvider);
    if (api == null) return;
    try {
      await api.unpair(device.id);
      if (selected) {
        final session = ref.read(sessionProvider);
        await ref.read(sessionProvider.notifier).update(session.copyWith(clearDevice: true));
      }
      ref.invalidate(cloudDevicesProvider);
    } on CloudException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.error.display)));
    }
  }
}

class _PairDialog extends StatefulWidget {
  const _PairDialog();

  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加设备'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('在设备上长按按键 3 秒，屏幕会显示 8 位配对码。'),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: '配对码', hintText: 'ABCD1234'),
            onSubmitted: (v) => Navigator.pop(context, v.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('绑定'),
        ),
      ],
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 96),
        Icon(Icons.sensors_off, size: 56, color: Theme.of(context).disabledColor),
        const SizedBox(height: 16),
        const Center(child: Text('还没有绑定设备')),
        const SizedBox(height: 8),
        const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text('设备不联网也能用。绑定只是为了远程查看和保存历史。', textAlign: TextAlign.center),
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 64),
        Icon(Icons.cloud_off, size: 48, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 16),
        Center(child: Text(message, textAlign: TextAlign.center)),
        const SizedBox(height: 16),
        Center(
          child: OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ),
      ],
    );
  }
}
