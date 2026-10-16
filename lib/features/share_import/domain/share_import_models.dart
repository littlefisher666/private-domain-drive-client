/// 单个分享导入条目：原生端解析并复制到本地缓存后的文件信息。
class ShareImportItem {
  const ShareImportItem({
    required this.id,
    required this.name,
    required this.size,
    required this.localPath,
  });

  final String id;
  final String name;
  final int size;

  /// Android 系统分享时复制到应用缓存目录的本地文件路径。
  final String localPath;
}

/// 已完整复制的分享批次（冷启动兜底路径一次性到达）。
class ShareImportCompleteBatch {
  const ShareImportCompleteBatch({
    required this.batchId,
    required this.items,
    required this.succeeded,
    required this.failed,
  });

  final String batchId;
  final List<ShareImportItem> items;
  final int succeeded;
  final int failed;
}

/// 分享导入批次的渐进接收进度；弹窗据此展示「正在导入 x/n」并控制
/// 确认按钮的启用时机（批次完成前禁用）。
class ShareImportBatchState {
  const ShareImportBatchState({
    required this.batchId,
    required this.total,
    required this.received,
    required this.finished,
    required this.failedCount,
  });

  final String batchId;

  /// 原生端解析出的分享文件总数。
  final int total;

  /// 已成功导入（复制完成）的文件数。
  final int received;
  final bool finished;
  final int failedCount;
}
