/// 历史数据点。
///
/// **两个来源共用这一份结构**：云端的分钟级聚合，与设备自己存的三小时。
/// 放在 contracts 而不是 cloud_api.dart 里，是因为局域网通道也要用它 ——
/// 让局域网通道去 import 云 API，依赖方向就反了。
library;

/// 分钟级历史数据点。原始秒级数据不入库 —— 见服务端架构 §4。
class HistoryPoint {
  const HistoryPoint({
    required this.bucketAt,
    required this.presenceS,
    this.co2Avg,
    this.co2Max,
    this.temperatureAvg,
    this.humidityAvg,
    this.noiseAvg,
    this.luxAvg,
  });

  final int bucketAt;
  final int presenceS;
  final double? co2Avg;
  final double? co2Max;
  final double? temperatureAvg;
  final double? humidityAvg;
  final double? noiseAvg;
  final double? luxAvg;

  factory HistoryPoint.fromJson(Map<String, Object?> j) => HistoryPoint(
    bucketAt: (j['bucket_at'] as num?)?.toInt() ?? 0,
    presenceS: (j['presence_s'] as num?)?.toInt() ?? 0,
    co2Avg: (j['co2_avg'] as num?)?.toDouble(),
    co2Max: (j['co2_max'] as num?)?.toDouble(),
    temperatureAvg: (j['temperature_avg'] as num?)?.toDouble(),
    humidityAvg: (j['humidity_avg'] as num?)?.toDouble(),
    noiseAvg: (j['noise_avg'] as num?)?.toDouble(),
    luxAvg: (j['lux_avg'] as num?)?.toDouble(),
  );
}

class HistoryResult {
  const HistoryResult({
    required this.points,
    required this.truncated,
    required this.retentionFloor,
  });

  final List<HistoryPoint> points;

  /// true 表示请求区间超出了套餐的保留期，已被裁剪。
  /// 界面应当提示用户，而不是让他以为那段时间真的没数据。
  final bool truncated;
  final int retentionFloor;
}
