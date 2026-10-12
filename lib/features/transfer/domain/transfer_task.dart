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
    );
  }

  static T? _enumValue<T extends Enum>(Iterable<T> values, Object? value) {
    if (value is! String) return null;
    for (final item in values) {
      if (item.name == value) return item;
    }
    return null;
  }
}
