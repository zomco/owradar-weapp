/// 应用外壳：底部导航 + 页面切换。
///
/// 四个页面对应用户的四种意图：
///   看板 —— 现在怎么样
///   历史 —— 之前怎么样
///   提醒 —— 什么时候叫我
///   设置 —— 连的是哪台、怎么连
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../dashboard/dashboard_page.dart';
import '../history/history_page.dart';
import '../rules/rules_page.dart';
import '../settings/settings_page.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  static const _pages = [DashboardPage(), HistoryPage(), RulesPage(), SettingsPage()];

  @override
  Widget build(BuildContext context) {
    // 有活跃告警时在「看板」上打个角标，用户切到别的页面也能看见
    final hasAlert = ref.watch(telemetryProvider).value?.hasActiveAlert ?? false;

    return Scaffold(
      // IndexedStack 而不是直接换 body：切页面时保留各页的滚动位置与状态，
      // 否则从历史切回看板会重新拉一次数据。
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: Badge(isLabelVisible: hasAlert, child: const Icon(Icons.dashboard_outlined)),
            selectedIcon: Badge(isLabelVisible: hasAlert, child: const Icon(Icons.dashboard)),
            label: '看板',
          ),
          const NavigationDestination(
            icon: Icon(Icons.show_chart_outlined),
            selectedIcon: Icon(Icons.show_chart),
            label: '历史',
          ),
          const NavigationDestination(
            icon: Icon(Icons.notifications_none),
            selectedIcon: Icon(Icons.notifications),
            label: '提醒',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
