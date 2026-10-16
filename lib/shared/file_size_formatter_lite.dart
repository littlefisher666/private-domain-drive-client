/// 轻量文件大小格式化：仅面向查看器等无依赖场景的体积文本展示。
class FileSizeFormatterLite {
  FileSizeFormatterLite._();

  static String format(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }
}
