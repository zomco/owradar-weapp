/// 受控的假通道。测试直接往里推快照与告警，并检查下发了什么命令。
///
/// 抽成共享文件而不是每个测试各写一个：两份假实现会各自漂移，
/// 到某天一个测试通过、另一个失败，而两者测的是同一件事。
library;

import 'dart:async';

import 'package:mmradar_app/core/contracts/command.dart';
import 'package:mmradar_app/core/contracts/telemetry.dart';
import 'package:mmradar_app/data/device_channel.dart';

class FakeChannel implements DeviceChannel {
  FakeChannel({Telemetry? initial, this.response, this.configResult})
    : _latest = initial;

  /// send() 的固定返回值。为 null 时返回成功。
  final CommandResult? response;

  /// get_config 的返回内容。需要读配置的页面用它。
  final Map<String, Object?>? configResult;

  final _telemetry = StreamController<Telemetry>.broadcast();
  final _alerts = StreamController<Alert>.broadcast();
  final _status = StreamController<ChannelStatus>.broadcast();
  Telemetry? _latest;

  /// 下发过的完整命令。只记命令名不够 —— 参数拼错时命令名是对的。
  final sent = <CommandRequest>[];

  /// 只要命令名的旧用法。
  List<String> get sentCommands => sent.map((r) => r.cmd).toList();

  void push(Telemetry t) {
    _latest = t;
    _telemetry.add(t);
  }

  void pushAlert(Alert a) => _alerts.add(a);
  void pushStatus(ChannelState s) => _status.add(ChannelStatus(ChannelKind.lan, s));

  @override
  ChannelKind get kind => ChannelKind.lan;
  @override
  Stream<Telemetry> get telemetry => _telemetry.stream;
  @override
  Stream<Alert> get alerts => _alerts.stream;
  @override
  Stream<ChannelStatus> get status => _status.stream;
  @override
  Telemetry? get latest => _latest;

  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}

  @override
  Future<CommandResult> send(CommandRequest request) async {
    sent.add(request);
    if (request.cmd == 'get_config' && configResult != null) {
      return CommandOk(configResult);
    }
    return response ?? const CommandOk(null);
  }

  @override
  Future<void> dispose() async {
    await _telemetry.close();
    await _alerts.close();
    await _status.close();
  }
}
