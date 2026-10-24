/// 分享准备进度；准备完成后由控制器置空。
class ShareProgress {
  const ShareProgress({
    required this.fileName,
    required this.receivedBytes,
    this.totalBytes,
    this.fileIndex = 1,
    this.fileCount = 1,
  });

  final String fileName;
  final int receivedBytes;
  final int? totalBytes;

  /// 当前文件在批次中的序号（从 1 开始）与批次文件总数。
  final int fileIndex;
  final int fileCount;

  bool get isBatch => fileCount > 1;

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }
}

enum FileShareOutcome { success, canceled, failed }

/// 用户取消分享准备：中止下载并清理临时文件，不弹出系统分享面板。
class FileShareCanceledException implements Exception {
  const FileShareCanceledException();
}
