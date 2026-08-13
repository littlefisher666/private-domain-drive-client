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
  });

  final String id;
  final String name;
  final TransferTaskType type;
  final TransferTaskStatus status;
  final double progress;
  final String? message;
  final String? target;

  TransferTask copyWith({
    String? id,
    String? name,
    TransferTaskType? type,
    TransferTaskStatus? status,
    double? progress,
    String? message,
    String? target,
  }) {
    return TransferTask(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      message: message ?? this.message,
      target: target ?? this.target,
    );
  }
}
