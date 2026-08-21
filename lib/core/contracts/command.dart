/// 命令请求与响应。见 workspace/contracts/commands.schema.json。
library;

class CommandRequest {
  CommandRequest(this.cmd, {this.params}) : reqId = _nextId();

  final String reqId;
  final String cmd;
  final Map<String, Object?>? params;

  static int _seq = 0;
  static String _nextId() => 'app-${DateTime.now().millisecondsSinceEpoch}-${_seq++}';

  Map<String, Object?> toJson() => {
    'req_id': reqId,
    'cmd': cmd,
    if (params != null) 'params': params,
  };
}

/// 契约定义的错误码，外加一个客户端补充的传输层错误。
enum ErrorCode {
  invalidParam,
  notFound,
  unauthorized,
  busy,
  sensorFault,
  storageError,
  unsupported,
  internal,

  /// 网络不通、超时。契约里没有 —— 它描述的是「请求没到设备」，
  /// 与设备处理失败是两回事，UI 的提示也该不同。
  transport;

  static const _wire = {
    'invalid_param': ErrorCode.invalidParam,
    'not_found': ErrorCode.notFound,
    'unauthorized': ErrorCode.unauthorized,
    'busy': ErrorCode.busy,
    'sensor_fault': ErrorCode.sensorFault,
    'storage_error': ErrorCode.storageError,
    'unsupported': ErrorCode.unsupported,
    'internal': ErrorCode.internal,
  };

  static ErrorCode parse(Object? v) => _wire[v] ?? ErrorCode.internal;

  /// 给用户看的话。技术错误码对用户没有意义。
  String get userMessage => switch (this) {
    ErrorCode.invalidParam => '参数不正确',
    ErrorCode.notFound => '找不到对象',
    ErrorCode.unauthorized => '需要重新登录',
    ErrorCode.busy => '设备正忙或已离线',
    ErrorCode.sensorFault => '传感器不可用',
    ErrorCode.storageError => '设备存储已满',
    ErrorCode.unsupported => '设备不支持该操作',
    ErrorCode.internal => '设备内部错误',
    ErrorCode.transport => '连接不上设备',
  };
}

class CommandError {
  const CommandError(this.code, [this.message = '']);

  final ErrorCode code;
  final String message;

  /// 优先显示设备给的具体说明；没有就退回通用文案。
  String get display => message.isNotEmpty ? message : code.userMessage;
}

/// 命令结果。成功带 result、失败带 error —— 用 sealed 保证二者互斥，
/// 调用方无法忘记处理失败分支。
sealed class CommandResult {
  const CommandResult();

  bool get isOk => this is CommandOk;

  CommandError? get errorOrNull => switch (this) {
    CommandFailed(:final error) => error,
    CommandOk() => null,
  };

  factory CommandResult.fromJson(Map<String, Object?> j) {
    if (j['ok'] == true) return CommandOk(j['result']);
    final err = j['error'];
    if (err is Map) {
      return CommandFailed(
        CommandError(ErrorCode.parse(err['code']), err['message'] as String? ?? ''),
      );
    }
    return const CommandFailed(CommandError(ErrorCode.internal));
  }
}

class CommandOk extends CommandResult {
  const CommandOk(this.result);

  final Object? result;

  Map<String, Object?>? get asMap =>
      result is Map ? (result! as Map).cast<String, Object?>() : null;
}

class CommandFailed extends CommandResult {
  const CommandFailed(this.error);

  final CommandError error;
}
