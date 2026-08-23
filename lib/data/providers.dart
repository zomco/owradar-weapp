/// Riverpod 依赖图。
///
/// UI 只订阅 [telemetryProvider] 与 [channelStatusProvider]，
/// **不知道背后是局域网还是云** —— 见 04-app-architecture.md §3。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/async_view.dart';
import '../core/contracts/command.dart';
import '../core/contracts/rule.dart';
import '../core/contracts/telemetry.dart';
import 'cloud_api.dart';
import 'cloud_channel.dart';
import 'device_channel.dart';
import 'lan_channel.dart';
import 'session.dart';

/// 局域网连接参数。真实场景由配网流程写入；
/// 开发期默认指向本机的设备模拟器（工作区 `npm run sim`）。
class DeviceEndpoint {
  const DeviceEndpoint({
    required this.host,
    required this.token,
    this.port = 80,
    this.name = '桌面助理',
  });

  final String host;
  final int port;
  final String token;
  final String name;

  static const DeviceEndpoint simulator = DeviceEndpoint(
    host: '127.0.0.1',
    port: 8080,
    token: 'dev-token',
    name: '模拟设备',
  );

  DeviceEndpoint copyWith({String? host, int? port, String? token, String? name}) => DeviceEndpoint(
    host: host ?? this.host,
    port: port ?? this.port,
    token: token ?? this.token,
    name: name ?? this.name,
  );

  @override
  bool operator ==(Object other) =>
      other is DeviceEndpoint &&
      other.host == host &&
      other.port == port &&
      other.token == token &&
      other.name == name;

  @override
  int get hashCode => Object.hash(host, port, token, name);
}

// ── 会话 ──────────────────────────────────────────────────

class SessionNotifier extends Notifier<Session> {
  final _store = SessionStore();

  @override
  Session build() {
    // 先给同步默认值，再异步补上持久化内容 ——
    // Notifier.build 不能是 async，而 UI 不该为读一次偏好设置卡住。
    unawaited(_restore());
    return const Session(mode: ConnectMode.lanOnly);
  }

  Future<void> _restore() async {
    // 迁移必须在 load 之前：旧版本把凭证放在 SharedPreferences 里，
    // 不先搬过来的话，升级上来的用户会莫名其妙被登出一次。
    await _store.migrateLegacySecrets();
    state = await _store.load();
  }

  Future<void> update(Session next) async {
    state = next;
    await _store.save(next);
  }

  Future<void> setMode(ConnectMode mode) => update(state.copyWith(mode: mode));

  Future<void> setCloudBaseUrl(String url) => update(state.copyWith(cloudBaseUrl: url));

  Future<void> signIn({required String email, required String access, required String refresh}) =>
      update(state.copyWith(email: email, accessToken: access, refreshToken: refresh));

  Future<void> signOut() => update(state.copyWith(clearAuth: true, clearDevice: true));

  /// 令牌刷新后落盘。
  ///
  /// 只动令牌，不碰 mode / deviceId —— 刷新是后台行为，
  /// 不该把用户正在看的设备切掉。
  Future<void> updateTokens(String access, String refresh) =>
      update(state.copyWith(accessToken: access, refreshToken: refresh));

  Future<void> selectDevice(String deviceId) => update(state.copyWith(deviceId: deviceId));
}

final sessionProvider = NotifierProvider<SessionNotifier, Session>(SessionNotifier.new);

// ── 局域网端点 ────────────────────────────────────────────

class EndpointNotifier extends Notifier<DeviceEndpoint> {
  @override
  DeviceEndpoint build() => DeviceEndpoint.simulator;

  void update(DeviceEndpoint next) => state = next;
  void setHost(String host, {int? port}) => state = state.copyWith(host: host, port: port);
  void setToken(String token) => state = state.copyWith(token: token);
}

final endpointProvider = NotifierProvider<EndpointNotifier, DeviceEndpoint>(EndpointNotifier.new);

// ── 云 API ────────────────────────────────────────────────

/// 云模式且已登录时才有实例；否则为 null。
/// 界面用 `== null` 判断「需要先登录」，不必自己拼判断条件。
final cloudApiProvider = Provider<CloudApi?>((ref) {
  final s = ref.watch(sessionProvider);
  if (s.mode != ConnectMode.cloudOnly || !s.isLoggedIn) return null;

  final api = CloudApi(
    baseUrl: s.cloudBaseUrl,
    accessToken: s.accessToken,
    refreshToken: s.refreshToken,
    // access token 只有 15 分钟。没有这两个回调的话，用户开着界面
    // 一刻钟就会莫名其妙全部报错，而错误信息只说「未授权」。
    onTokensRefreshed: (tokens) {
      // 不用 ref.read(...notifier)：这里可能在 Provider 已被 dispose
      // 之后回调（请求还在飞），那时候读 notifier 会抛。
      if (!ref.mounted) return;
      ref.read(sessionProvider.notifier).updateTokens(tokens.access, tokens.refresh);
    },
    onSessionExpired: () {
      if (!ref.mounted) return;
      ref.read(sessionProvider.notifier).signOut();
    },
  );
  ref.onDispose(api.close);
  return api;
});

/// 账号信息与日报偏好。仅云模式有意义。
final accountProvider = FutureProvider<AccountInfo>((ref) async {
  final api = ref.watch(cloudApiProvider);
  if (api == null) {
    throw const CloudException(CommandError(ErrorCode.unauthorized, '未登录'));
  }
  return api.account();
}, retry: backOffThenGiveUp);

/// 用户绑定的设备列表。仅云模式有意义。
final cloudDevicesProvider = FutureProvider<List<CloudDevice>>((ref) async {
  final api = ref.watch(cloudApiProvider);
  if (api == null) return const [];
  return api.listDevices();
}, retry: backOffThenGiveUp);

// ── 通道选路 ──────────────────────────────────────────────

/// 当前通道。
///
/// 按会话模式选实现。UI 完全感知不到差别 ——
/// 这正是 [DeviceChannel] 抽象存在的意义。
final channelProvider = Provider<DeviceChannel>((ref) {
  final session = ref.watch(sessionProvider);

  if (session.cloudReady) {
    final api = ref.watch(cloudApiProvider)!;
    final channel = CloudChannel(api: api, deviceId: session.deviceId!);
    unawaited(channel.connect());
    ref.onDispose(channel.dispose);
    return channel;
  }

  final ep = ref.watch(endpointProvider);
  final channel = LanChannel(host: ep.host, port: ep.port, token: ep.token);
  // 不 await —— connect 内部自带重试，阻塞 Provider 构建没有意义
  unawaited(channel.connect());
  ref.onDispose(channel.dispose);
  return channel;
});

// ── 实时数据 ──────────────────────────────────────────────

/// 完整快照流。**Delta 的合并已在 Channel 层完成**，
/// UI 永远只面对完整对象（契约 §5）。
final telemetryProvider = StreamProvider<Telemetry>((ref) async* {
  final channel = ref.watch(channelProvider);

  // 已有快照就先吐一份，避免重建 Provider 时界面闪一下 loading
  final cached = channel.latest;
  if (cached != null) yield cached;

  yield* channel.telemetry;
});

final channelStatusProvider = StreamProvider<ChannelStatus>((ref) {
  return ref.watch(channelProvider).status;
});

final latestAlertProvider = StreamProvider<Alert>((ref) {
  return ref.watch(channelProvider).alerts;
});

// ── 规则 ──────────────────────────────────────────────────

/// 设备当前的规则列表。
///
/// 走 get_config 而不是云端的规则接口 —— 契约里规则是配置的一部分，
/// 且**设备端的 NVS 才是权威**（见 01-system-architecture.md §5）。
final rulesProvider = FutureProvider<List<Rule>>((ref) async {
  final channel = ref.watch(channelProvider);
  final result = await channel.getConfig();

  switch (result) {
    case CommandFailed(:final error):
      throw Exception(error.display);
    case CommandOk(:final result):
      final cfg = result is Map ? result.cast<String, Object?>() : const <String, Object?>{};
      final list = cfg['rules'];
      if (list is! List) return const [];
      return list
          .whereType<Map<Object?, Object?>>()
          .map((r) => Rule.fromJson(r.cast<String, Object?>()))
          .toList();
  }
}, retry: backOffThenGiveUp);

// ── 历史 ──────────────────────────────────────────────────

/// 历史查询的时间跨度（秒）。由历史页写入。
/// 用 Notifier 而非 legacy 的 StateProvider —— 后者在 Riverpod 3 已移出主导出。
class HistorySpanNotifier extends Notifier<int> {
  @override
  int build() => 3600;

  void set(int seconds) => state = seconds;
}

final historySpanProvider = NotifierProvider<HistorySpanNotifier, int>(HistorySpanNotifier.new);

/// 历史页当前查看的指标。
class HistoryMetricNotifier extends Notifier<Metric> {
  @override
  Metric build() => Metric.co2;

  void set(Metric m) => state = m;
}

final historyMetricProvider = NotifierProvider<HistoryMetricNotifier, Metric>(
  HistoryMetricNotifier.new,
);

final historyProvider = FutureProvider<HistoryResult>((ref) async {
  final api = ref.watch(cloudApiProvider);
  final session = ref.watch(sessionProvider);
  final span = ref.watch(historySpanProvider);

  if (api == null || session.deviceId == null) {
    return const HistoryResult(points: [], truncated: false, retentionFloor: 0);
  }

  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return api.history(session.deviceId!, from: now - span, to: now);
}, retry: backOffThenGiveUp);

// ── 派生 ──────────────────────────────────────────────────

/// 整机风险等级。
/// **不重新计算** —— 直接用设备下发的值，保证四端显示一致。
final riskProvider = Provider<RiskLevel?>((ref) {
  return ref.watch(telemetryProvider).value?.riskLevel;
});
