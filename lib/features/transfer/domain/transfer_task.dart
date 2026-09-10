enum TransferTaskStatus {
  pending,
  running,
  success,
  failed,
  canceled,
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
      sourcePath: sourcePath ?? this.sourcePath,
      batchId: batchId ?? this.batchId,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
      error: error ?? this.error,
    );
  }
}
