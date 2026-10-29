import 'recycle_bin_entry.dart';

/// 批量恢复/彻底删除的逐条执行结果：失败条目保留在回收站。
class RecycleBinBatchResult {
  const RecycleBinBatchResult({
    required this.succeeded,
    required this.failed,
  });

  final List<RecycleBinEntry> succeeded;
  final List<RecycleBinEntry> failed;

  int get successCount => succeeded.length;
  int get failureCount => failed.length;
}
