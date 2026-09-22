import 'dart:convert';

class RecycleBinEntry {
  const RecycleBinEntry({
    required this.id,
    required this.name,
    required this.originalPath,
    required this.isDirectory,
    required this.deletedAt,
    required this.objects,
  });

  final String id;
  final String name;
  final String originalPath;
  final bool isDirectory;
  final DateTime deletedAt;
  final Map<String, String> objects;

  DateTime get expiresAt => deletedAt.add(const Duration(days: 30));

  Map<String, Object> toJson() => <String, Object>{
        'id': id,
        'name': name,
        'originalPath': originalPath,
        'isDirectory': isDirectory,
        'deletedAt': deletedAt.toUtc().toIso8601String(),
        'objects': objects,
      };

  factory RecycleBinEntry.fromJson(Map<String, dynamic> json) {
    final objects = (json['objects'] as Map? ?? const <String, String>{})
        .map((key, value) => MapEntry(key.toString(), value.toString()));
    return RecycleBinEntry(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '已删除项目',
      originalPath: json['originalPath']?.toString() ?? '',
      isDirectory: json['isDirectory'] == true,
      deletedAt: DateTime.parse(json['deletedAt'].toString()).toLocal(),
      objects: objects,
    );
  }

  static RecycleBinEntry decode(String source) =>
      RecycleBinEntry.fromJson(jsonDecode(source) as Map<String, dynamic>);

  String encode() => jsonEncode(toJson());
}
