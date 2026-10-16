/// 批量下载入队结果：批次 id、展开后的文件数与选中的文件夹数。
class BatchDownloadEnqueueResult {
  const BatchDownloadEnqueueResult({
    required this.batchId,
    required this.fileCount,
    required this.directoryCount,
  });

  final String batchId;
  final int fileCount;
  final int directoryCount;
}

/// 上传目标已存在时的用户处置决策。
enum UploadConflictResolution { skip, overwrite, keepBoth }
