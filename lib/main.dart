/// mmRadar 桌面助理客户端入口。
///
/// 架构说明在工作区：docs/architecture/04-app-architecture.md
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/shell/app_shell.dart';

void main() {
  runApp(const ProviderScope(child: MmRadarApp()));
}

class MmRadarApp extends StatelessWidget {
  const MmRadarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mmRadar',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const AppShell(),
    );
  }

  /// 主色取风险配色里的 good（绿），与设备屏幕同源。
  static ThemeData _theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E8E4E), brightness: brightness),
    cardTheme: const CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(14))),
    ),
  );
}
