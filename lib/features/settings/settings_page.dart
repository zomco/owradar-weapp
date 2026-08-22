/// 设置：连的是哪台设备、怎么连。
///
/// 连接方式放在最上面且不藏在二级菜单里 ——
/// 「可以完全关掉云」是产品承诺（00-product-spec.md US-5），
/// 不是高级选项。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../data/session.dart';
import '../devices/devices_page.dart';
import 'login_page.dart';
import 'report_settings.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _SectionHeader('连接方式'),
          _ModeSelector(mode: session.mode),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Text(session.mode.description, style: Theme.of(context).textTheme.bodySmall),
          ),
          const Divider(height: 1),

          if (session.mode == ConnectMode.lanOnly) ...[
            const _SectionHeader('局域网设备'),
            const _LanSettings(),
          ] else ...[
            const _SectionHeader('云账号'),
            _CloudSettings(session: session),
          ],

          const Divider(height: 1),
          const _SectionHeader('关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('mmRadar'),
            subtitle: Text('桌面环境助理 · 契约版本 1'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}

class _ModeSelector extends ConsumerWidget {
  const _ModeSelector({required this.mode});
  final ConnectMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SegmentedButton<ConnectMode>(
        segments: [
          for (final m in ConnectMode.values)
            ButtonSegment(
              value: m,
              label: Text(m.label),
              icon: Icon(m == ConnectMode.lanOnly ? Icons.wifi : Icons.cloud_outlined),
            ),
        ],
        selected: {mode},
        onSelectionChanged: (s) => ref.read(sessionProvider.notifier).setMode(s.first),
      ),
    );
  }
}

// ── 局域网 ────────────────────────────────────────────────

class _LanSettings extends ConsumerStatefulWidget {
  const _LanSettings();

  @override
  ConsumerState<_LanSettings> createState() => _LanSettingsState();
}

class _LanSettingsState extends ConsumerState<_LanSettings> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _token;

  @override
  void initState() {
    super.initState();
    final ep = ref.read(endpointProvider);
    _host = TextEditingController(text: ep.host);
    _port = TextEditingController(text: '${ep.port}');
    _token = TextEditingController(text: ep.token);
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  void _apply() {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('端口不合法')));
      return;
    }
    ref
        .read(endpointProvider.notifier)
        .update(DeviceEndpoint(host: _host.text.trim(), port: port, token: _token.text.trim()));
    // 端点变了要重建通道，否则还连着旧地址
    ref.invalidate(channelProvider);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已重新连接')));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: '设备地址',
              helperText: 'mDNS 名称或 IP，例如 mmradar-a1b2.local',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '端口'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            decoration: const InputDecoration(
              labelText: '配对 Token',
              // 局域网也要鉴权 —— CLAUDE.md §7 安全红线
              helperText: '设备屏幕上显示的配对码。内网也需要鉴权。',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _apply,
            icon: const Icon(Icons.link),
            label: const Text('保存并重连'),
          ),
        ],
      ),
    );
  }
}

// ── 云 ────────────────────────────────────────────────────

class _CloudSettings extends ConsumerWidget {
  const _CloudSettings({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!session.isLoggedIn) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('登录后可远程查看设备、保存历史曲线、接收推送告警。', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () =>
                  Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => const LoginPage())),
              icon: const Icon(Icons.login),
              label: const Text('登录'),
            ),
            const SizedBox(height: 8),
            const _CloudUrlField(),
          ],
        ),
      );
    }

    final devices = ref.watch(cloudDevicesProvider);
    final currentName = devices.value
        ?.where((d) => d.id == session.deviceId)
        .map((d) => d.name)
        .firstOrNull;

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: Text(session.email ?? '已登录'),
          subtitle: const Text('云账号'),
        ),
        ListTile(
          leading: const Icon(Icons.sensors),
          title: const Text('我的设备'),
          subtitle: Text(session.deviceId == null ? '还没选择设备' : currentName ?? session.deviceId!),
          trailing: const Icon(Icons.chevron_right),
          onTap: () =>
              Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => const DevicesPage())),
        ),
        ListTile(
          leading: const Icon(Icons.summarize_outlined),
          title: const Text('日报'),
          subtitle: const Text('每天收一份前一天的回顾'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ReportSettingsPage()),
          ),
        ),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: _CloudUrlField()),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: () => _confirmSignOut(context, ref),
            icon: const Icon(Icons.logout),
            label: const Text('退出登录'),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录？'),
        content: const Text('设备本身不受影响，仍会继续监测并按规则告警。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('退出')),
        ],
      ),
    );
    if (ok ?? false) {
      await ref.read(sessionProvider.notifier).signOut();
    }
  }
}

/// 服务端地址。开发期指向本机 wrangler；正式版指向生产域名。
class _CloudUrlField extends ConsumerStatefulWidget {
  const _CloudUrlField();

  @override
  ConsumerState<_CloudUrlField> createState() => _CloudUrlFieldState();
}

class _CloudUrlFieldState extends ConsumerState<_CloudUrlField> {
  late final TextEditingController _c = TextEditingController(
    text: ref.read(sessionProvider).cloudBaseUrl,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      decoration: InputDecoration(
        labelText: '服务端地址',
        helperText: '自建服务端时改这里',
        suffixIcon: IconButton(
          icon: const Icon(Icons.check),
          onPressed: () {
            ref.read(sessionProvider.notifier).setCloudBaseUrl(_c.text.trim());
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
          },
        ),
      ),
    );
  }
}
