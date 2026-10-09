import 'dart:convert';

/// 未完成移动任务的 OSS manifest（`shared/.moves/<id>/manifest.json`）。
/// 只记录任务本身，不记录逐对象进度——执行幂等使重跑天然正确。
class MoveTaskEntry {
  const MoveTaskEntry({
    required this.id,
    required this.sourcePrefixes,
    required this.targetPrefix,
    required this.createdAt,
    this.destinations = const <String>[],
  });

  final String id;

  /// 源前缀列表（目录以 `/` 结尾，文件为完整对象 key）。
  final List<String> sourcePrefixes;

  /// 目标目录前缀（以 `/` 结尾）。
  final String targetPrefix;
  final DateTime createdAt;

  /// 与 sourcePrefixes 平行的目标侧落点（冲突保留两者时为改名后的前缀）；
  /// 旧 manifest 可能缺失，此时按 targetPrefix + 源名推导。
  final List<String> destinations;

  Map<String, Object> toJson() => <String, Object>{
        'id': id,
        'sourcePrefixes': sourcePrefixes,
        'targetPrefix': targetPrefix,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (destinations.isNotEmpty) 'destinations': destinations,
      };

  factory MoveTaskEntry.fromJson(Map<String, dynamic> json) {
    return MoveTaskEntry(
      id: json['id']?.toString() ?? '',
      sourcePrefixes: (json['sourcePrefixes'] as List? ?? const <String>[])
          .map((value) => value.toString())
          .toList(growable: false),
      targetPrefix: json['targetPrefix']?.toString() ?? '',
      createdAt: DateTime.parse(json['createdAt'].toString()).toLocal(),
      destinations: (json['destinations'] as List? ?? const <String>[])
          .map((value) => value.toString())
          .toList(growable: false),
    );
  }

  static MoveTaskEntry decode(String source) =>
      MoveTaskEntry.fromJson(jsonDecode(source) as Map<String, dynamic>);

  String encode() => jsonEncode(toJson());
}
