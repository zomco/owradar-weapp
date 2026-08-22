/// 设备通道抽象。
///
/// **UI 只依赖这个接口，不知道数据来自局域网还是云。**
/// 见 04-app-architecture.md §3。
///
/// 三种实现：
///   LanChannel    局域网 HTTP + WebSocket —— 延迟低、不消耗云配额、无云也可用
///   CloudChannel  云 REST + WSS —— 不在同一网段时使用
///   BleChannel    仅配网期，需原生平台支持（web 上不可用）
library;

import 'dart:async';

import '../core/contracts/command.dart';
import '../core/contracts/rule.dart';
import '../core/contracts/telemetry.dart';

enum ChannelKind {
  lan,
  cloud,
  ble;

  String get label => switch (this) {
    ChannelKind.lan => '局域网直连',
    ChannelKind.cloud => '云端',
    ChannelKind.ble => '蓝牙配网',
  };
}

/// 通道连接状态。
/// 刻意不叫 ConnectionState —— Flutter 的 material 库里已有同名类型，
/// 同时 import 会造成歧义。
enum ChannelState {
  idle,
  connecting,
  connected,
  reconnecting,
  failed;

  bool get isUsable => this == ChannelState.connected;
}

class ChannelStatus {
  const ChannelStatus(this.kind, this.state, {this.detail = ''});

  final ChannelKind kind;
  final ChannelState state;
  final String detail;
}

abstract class DeviceChannel {
  ChannelKind get kind;

  /// 完整快照流。**Delta 已在实现内部合并**，
  /// UI 永远只面对完整对象（契约 §5）。
  Stream<Telemetry> get telemetry;

  Stream<Alert> get alerts;

  Stream<ChannelStatus> get status;

  /// 当前已知的最新快照。刚订阅时用它立刻渲染，不必等第一帧到达。
  Telemetry? get latest;

  Future<void> connect();

  Future<void> disconnect();

  /// 下发命令。传输失败也返回 CommandFailed 而不是抛异常 ——
  /// 调用方只需处理一种失败形态。
  Future<CommandResult> send(CommandRequest request);

  Future<void> dispose();
}

/// 几个常用命令的便捷封装。
/// 放在扩展里而不是接口上：它们只是 [DeviceChannel.send] 的语法糖，
/// 新实现不该被迫重写一遍。
extension DeviceCommands on DeviceChannel {
  Future<CommandResult> getSnapshot() => send(CommandRequest('get_snapshot'));

  Future<CommandResult> getConfig() => send(CommandRequest('get_config'));

  Future<CommandResult> setRule(Rule rule) =>
      send(CommandRequest('set_rule', params: rule.toJson()));

  Future<CommandResult> deleteRule(String id) =>
      send(CommandRequest('delete_rule', params: {'id': id}));

  /// 引导式标定：读当前距离，自动设 ±30cm 区间。
  /// 「距离门」这个概念不该暴露给用户。
  Future<CommandResult> calibrateZone() => send(CommandRequest('calibrate_zone'));

  Future<CommandResult> setZone({required int minCm, required int maxCm}) =>
      send(CommandRequest('set_zone', params: {'min_cm': minCm, 'max_cm': maxCm}));

  /// 户外新鲜空气约 420ppm。
  Future<CommandResult> calibrateCo2({int referencePpm = 420}) =>
      send(CommandRequest('calibrate_co2', params: {'reference_ppm': referencePpm}));

  Future<CommandResult> setBrightness(int pct) =>
      send(CommandRequest('set_display', params: {'brightness_pct': pct}));

  /// 多设备时用来确认「是哪一台」。
  Future<CommandResult> identify() => send(CommandRequest('identify'));
}
