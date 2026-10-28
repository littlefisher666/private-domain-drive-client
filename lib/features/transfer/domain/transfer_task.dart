enum TransferTaskStatus {
  pending,
  running,
  success,
  failed,
  canceled,

  /// 上传进程被中断后恢复出的任务状态：上次进程未跑完，等待用户继续或放弃。
  interrupted,
}

enum TransferTaskType {
  upload,
  download,
}

class TransferTask {
  const TransferTask({
    required this.id,
    required this.name,
    required this.type,
    required this.status,
    required this.progress,
    this.message,
    this.target,
    this.targetDir,
    this.sourcePath,
    this.batchId,
    this.transferredBytes = 0,
    this.totalBytes,
    this.bytesPerSecond,
    this.error,
    this.queuedAt,
    this.startedAt,
    this.lastStartedAt,
    this.finishedAt,
    this.activeDurationMs = 0,
    this.totalTransferredBytes = 0,
    this.attemptCount = 1,
  });

  final String id;
  final String name;
  final TransferTaskType type;
  final TransferTaskStatus status;
  final double progress;
  final String? message;
  final String? target;

  /// 上传目标的内部目录路径（如 `/共享空间/照片/`），用于持久化恢复后
  /// 重建上传对象键；下载任务不使用。
  final String? targetDir;
  final String? sourcePath;
  final String? batchId;
  final int transferredBytes;
  final int? totalBytes;
  final double? bytesPerSecond;
  final String? error;

  /// 首次入队时间，重试不覆盖。
  final DateTime? queuedAt;

  /// 首次开始传输时间。
  final DateTime? startedAt;

  /// 最近一次开始传输时间，每次进入传输中状态更新。
  final DateTime? lastStartedAt;

  /// 最近一次终态时间，重试重新入队时清空。
  final DateTime? finishedAt;

  /// 跨尝试累计的实际传输时长（毫秒，单调时钟统计）。
  final int activeDurationMs;

  /// 跨尝试累计的实际传输字节数。
  final int totalTransferredBytes;

  /// 尝试次数：首次入队为 1，用户重试 +1，暂停继续不增加。
  final int attemptCount;

  bool get isFinished =>
      status == TransferTaskStatus.success ||
      status == TransferTaskStatus.failed ||
      status == TransferTaskStatus.canceled;

  /// 入队时间：优先使用显式字段，旧记录回退到 id 内嵌的微秒时间戳。
  DateTime? get queuedTime => queuedAt ?? queuedAtFromId(id);

  /// 平均速度（字节/秒）：累计实际字节除以累计实际传输时长。
  /// 时长为零或累计字节未知时返回 null，界面展示占位符。
  double? get averageBytesPerSecond {
    if (activeDurationMs <= 0 || totalTransferredBytes <= 0) return null;
    return totalTransferredBytes / (activeDurationMs / 1000);
  }

  TransferTask copyWith({
    String? id,
    String? name,
    TransferTaskType? type,
    TransferTaskStatus? status,
    double? progress,
    String? message,
    String? target,
    String? targetDir,
    String? sourcePath,
    String? batchId,
    int? transferredBytes,
    int? totalBytes,
    double? bytesPerSecond,
    String? error,
    DateTime? queuedAt,
    DateTime? startedAt,
    DateTime? lastStartedAt,
    DateTime? finishedAt,
    bool clearFinishedAt = false,
    int? activeDurationMs,
    int? totalTransferredBytes,
    int? attemptCount,
  }) {
    return TransferTask(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      message: message ?? this.message,
      target: target ?? this.target,
      targetDir: targetDir ?? this.targetDir,
      sourcePath: sourcePath ?? this.sourcePath,
      batchId: batchId ?? this.batchId,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
      error: error ?? this.error,
      queuedAt: queuedAt ?? this.queuedAt,
      startedAt: startedAt ?? this.startedAt,
      lastStartedAt: lastStartedAt ?? this.lastStartedAt,
      finishedAt: clearFinishedAt ? null : (finishedAt ?? this.finishedAt),
      activeDurationMs: activeDurationMs ?? this.activeDurationMs,
      totalTransferredBytes:
          totalTransferredBytes ?? this.totalTransferredBytes,
      attemptCount: attemptCount ?? this.attemptCount,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'type': type.name,
      'status': status.name,
      'progress': progress,
      'message': message,
      'target': target,
      'targetDir': targetDir,
      'sourcePath': sourcePath,
      'batchId': batchId,
      'transferredBytes': transferredBytes,
      'totalBytes': totalBytes,
      'bytesPerSecond': bytesPerSecond,
      'error': error,
      'queuedAt': queuedAt?.toUtc().millisecondsSinceEpoch,
      'startedAt': startedAt?.toUtc().millisecondsSinceEpoch,
      'lastStartedAt': lastStartedAt?.toUtc().millisecondsSinceEpoch,
      'finishedAt': finishedAt?.toUtc().millisecondsSinceEpoch,
      'activeDurationMs': activeDurationMs,
      'totalTransferredBytes': totalTransferredBytes,
      'attemptCount': attemptCount,
    };
  }

  static TransferTask? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final type = _enumValue(TransferTaskType.values, json['type']);
    final status = _enumValue(TransferTaskStatus.values, json['status']);
    final progress = json['progress'];
    if (id is! String ||
        name is! String ||
        type == null ||
        status == null ||
        progress is! num) {
      return null;
    }
    return TransferTask(
      id: id,
      name: name,
      type: type,
      status: status,
      progress: progress.toDouble(),
      message: json['message'] as String?,
      target: json['target'] as String?,
      targetDir: json['targetDir'] as String?,
      sourcePath: json['sourcePath'] as String?,
      batchId: json['batchId'] as String?,
      transferredBytes: (json['transferredBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt(),
      bytesPerSecond: (json['bytesPerSecond'] as num?)?.toDouble(),
      error: json['error'] as String?,
      queuedAt:
          _dateFromEpochMs(json['queuedAt']) ?? queuedAtFromId(id),
      startedAt: _dateFromEpochMs(json['startedAt']),
      lastStartedAt: _dateFromEpochMs(json['lastStartedAt']),
      finishedAt: _dateFromEpochMs(json['finishedAt']),
      activeDurationMs: (json['activeDurationMs'] as num?)?.toInt() ?? 0,
      totalTransferredBytes:
          (json['totalTransferredBytes'] as num?)?.toInt() ?? 0,
      attemptCount: (json['attemptCount'] as num?)?.toInt() ?? 1,
    );
  }

  /// 旧记录兜底：任务 id 形如 `download-<microsecondsSinceEpoch>-<n>`，
  /// 解析失败或时间明显越界时返回 null。
  static DateTime? queuedAtFromId(String id) {
    for (final segment in id.split('-')) {
      if (segment.length < 16) continue;
      final micros = int.tryParse(segment);
      if (micros == null) continue;
      final value = DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
      if (value.year >= 2000 && value.year <= 2100) return value;
    }
    return null;
  }

  static DateTime? _dateFromEpochMs(Object? value) {
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
    }
    return null;
  }

  static T? _enumValue<T extends Enum>(Iterable<T> values, Object? value) {
    if (value is! String) return null;
    for (final item in values) {
      if (item.name == value) return item;
    }
    return null;
  }
}
