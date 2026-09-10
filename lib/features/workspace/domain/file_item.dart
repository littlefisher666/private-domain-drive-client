class FileItem {
  const FileItem({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size,
    this.updatedAt,
    this.takenAt,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int? size;
  final DateTime? updatedAt;

  /// 图片 EXIF 中的拍摄时间；非图片或缺少 EXIF 时为空。
  final DateTime? takenAt;
}

enum BrowseMode { list, grid }

enum FileSortOption {
  updatedNewest,
  updatedOldest,
  takenNewest,
  takenOldest,
  nameAscending,
  nameDescending,
}

extension FileSortOptionX on FileSortOption {
  String get label => switch (this) {
        FileSortOption.updatedNewest => '更新时间（最新优先）',
        FileSortOption.updatedOldest => '更新时间（最早优先）',
        FileSortOption.takenNewest => '拍摄时间（最新优先）',
        FileSortOption.takenOldest => '拍摄时间（最早优先）',
        FileSortOption.nameAscending => '文件名（A-Z）',
        FileSortOption.nameDescending => '文件名（Z-A）',
      };

  String get shortLabel => switch (this) {
        FileSortOption.updatedNewest => '最新',
        FileSortOption.updatedOldest => '最早',
        FileSortOption.takenNewest => '拍摄时间',
        FileSortOption.takenOldest => '拍摄时间',
        FileSortOption.nameAscending => '名称',
        FileSortOption.nameDescending => '名称',
      };

  bool get needsTakenAt =>
      this == FileSortOption.takenNewest || this == FileSortOption.takenOldest;
}

enum FileKind { folder, image, pdf, text, file }

class ImageThumbnailSpec {
  const ImageThumbnailSpec._();

  static const size = 320;
  static const previewSize = 1600;

  static String process({int width = size, int height = size}) =>
      'image/resize,m_lfit,w_$width,h_$height';
}

extension FileItemX on FileItem {
  /// 用于区分同一路径对象的不同版本，避免对象更新后复用旧缩略图。
  String get objectVersionToken {
    final modified = updatedAt?.toUtc().toIso8601String() ?? '';
    return '${size ?? ''}|$modified';
  }

  FileKind get kind {
    if (isDirectory) {
      return FileKind.folder;
    }
    final lower = name.toLowerCase();
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.heic')) {
      return FileKind.image;
    }
    if (lower.endsWith('.pdf')) {
      return FileKind.pdf;
    }
    if (lower.endsWith('.txt') ||
        lower.endsWith('.md') ||
        lower.endsWith('.json') ||
        lower.endsWith('.yaml') ||
        lower.endsWith('.yml') ||
        lower.endsWith('.log') ||
        lower.endsWith('.csv')) {
      return FileKind.text;
    }
    return FileKind.file;
  }

  String get typeLabel => switch (kind) {
        FileKind.folder => '文件夹',
        FileKind.image => '图片',
        FileKind.pdf => 'PDF',
        FileKind.text => '文本',
        FileKind.file => '文件',
      };

  FileItem copyWith({
    String? path,
    String? name,
    bool? isDirectory,
    int? size,
    DateTime? updatedAt,
    DateTime? takenAt,
  }) {
    return FileItem(
      path: path ?? this.path,
      name: name ?? this.name,
      isDirectory: isDirectory ?? this.isDirectory,
      size: size ?? this.size,
      updatedAt: updatedAt ?? this.updatedAt,
      takenAt: takenAt ?? this.takenAt,
    );
  }
}

List<FileItem> sortFileItems(
  Iterable<FileItem> source,
  FileSortOption option,
) {
  final items = source.toList(growable: false);
  items.sort((left, right) {
    // 目录始终排在文件之前，避免排序后破坏目录浏览体验。
    if (left.isDirectory != right.isDirectory) {
      return left.isDirectory ? -1 : 1;
    }
    final comparison = switch (option) {
      FileSortOption.nameAscending =>
        left.name.toLowerCase().compareTo(right.name.toLowerCase()),
      FileSortOption.nameDescending =>
        right.name.toLowerCase().compareTo(left.name.toLowerCase()),
      FileSortOption.updatedNewest =>
        _compareDate(left.updatedAt, right.updatedAt, descending: true),
      FileSortOption.updatedOldest =>
        _compareDate(left.updatedAt, right.updatedAt),
      FileSortOption.takenNewest =>
        _compareDate(left.takenAt, right.takenAt, descending: true),
      FileSortOption.takenOldest => _compareDate(left.takenAt, right.takenAt),
    };
    if (comparison != 0) return comparison;
    // 没有拍摄时间时，以及同一日期时，使用更新时间和名称保证稳定结果。
    final updated =
        _compareDate(left.updatedAt, right.updatedAt, descending: true);
    return updated != 0
        ? updated
        : left.name.toLowerCase().compareTo(right.name.toLowerCase());
  });
  return items;
}

int _compareDate(
  DateTime? left,
  DateTime? right, {
  bool descending = false,
}) {
  if (left == null && right == null) return 0;
  if (left == null) return 1;
  if (right == null) return -1;
  final comparison = left.compareTo(right);
  return descending ? -comparison : comparison;
}
