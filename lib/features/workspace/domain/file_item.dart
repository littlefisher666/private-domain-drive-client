class FileItem {
  const FileItem({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size,
    this.updatedAt,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int? size;
  final DateTime? updatedAt;
}

enum BrowseMode { list, grid }

enum FileKind { folder, image, pdf, text, file }

extension FileItemX on FileItem {
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
  }) {
    return FileItem(
      path: path ?? this.path,
      name: name ?? this.name,
      isDirectory: isDirectory ?? this.isDirectory,
      size: size ?? this.size,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
