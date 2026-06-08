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
