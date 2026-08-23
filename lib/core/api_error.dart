/// API 调用失败。
///
/// 云与局域网共用：两边失败的**形态**是一样的（一个错误码加一句人话），
/// 调用方不必为两条链路各写一遍错误处理。
///
/// 名字里的 Cloud 是历史遗留，改名会波及一大片 import，不值当。
library;

import 'contracts/command.dart';

/// 云端 API 调用失败。用 [CommandError] 复用同一套错误码与用户文案。
class CloudException implements Exception {
  const CloudException(this.error);
  final CommandError error;

  @override
  String toString() => error.display;
}

