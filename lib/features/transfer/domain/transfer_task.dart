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
  });

  final String id;
  final String name;
  final TransferTaskType type;
  final TransferTaskStatus status;
  final double progress;
  final String? message;
}
