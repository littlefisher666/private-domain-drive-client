import 'transfer_task.dart';

/// 传输中心类型筛选用计数：保留范围内全部历史记录与内存中未结束任务之和。
class TransferTypeCounts {
  const TransferTypeCounts({required this.upload, required this.download});

  const TransferTypeCounts.empty()
      : upload = 0,
        download = 0;

  final int upload;
  final int download;

  int get total => upload + download;

  int of(TransferTaskType type) {
    return switch (type) {
      TransferTaskType.upload => upload,
      TransferTaskType.download => download,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is TransferTypeCounts &&
        other.upload == upload &&
        other.download == download;
  }

  @override
  int get hashCode => Object.hash(upload, download);
}
