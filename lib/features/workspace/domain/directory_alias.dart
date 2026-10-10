import 'dart:convert';
import 'dart:math';

/// 虚拟目录别名：指向真实目录前缀的应用层链接，
/// 元数据存储在 `shared/.aliases/links.json`。
class DirectoryAlias {
  const DirectoryAlias({
    required this.id,
    required this.name,
    required this.targetPrefix,
    required this.parentPrefix,
    this.createdBy,
    this.createdAt,
  });

  final String id;

  /// 挂载层级内展示的别名名称，须与同层级真实条目及其他别名保持唯一。
  final String name;

  /// 完整真实目录前缀（含会话根前缀与结尾 `/`），直接用于 ListObjects。
  final String targetPrefix;

  /// 挂载层级（完整目录前缀，含结尾 `/`），决定别名在哪个层级渲染。
  final String parentPrefix;

  /// 创建时的登录用户名，仅用于展示，缺失按空值展示。
  final String? createdBy;
  final DateTime? createdAt;

  DirectoryAlias copyWith({String? name}) => DirectoryAlias(
        id: id,
        name: name ?? this.name,
        targetPrefix: targetPrefix,
        parentPrefix: parentPrefix,
        createdBy: createdBy,
        createdAt: createdAt,
      );

  static DirectoryAlias create({
    required String name,
    required String targetPrefix,
    required String parentPrefix,
    required String createdBy,
  }) =>
      DirectoryAlias(
        id: _generateId(),
        name: name,
        targetPrefix: targetPrefix,
        parentPrefix: parentPrefix,
        createdBy: createdBy,
        createdAt: DateTime.now(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'targetPrefix': targetPrefix,
        'parent': parentPrefix,
        if (createdBy != null && createdBy!.isNotEmpty) 'createdBy': createdBy,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
      };

  /// 单条数据损坏（缺少 id/name/targetPrefix）时跳过该条目；
  /// [defaultParentPrefix] 兜底无 `parent` 字段的存量条目；
  /// createdBy/createdAt 缺失按空值解析。
  static DirectoryAlias? tryDecode(
    Object? raw, {
    required String defaultParentPrefix,
  }) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final targetPrefix = raw['targetPrefix'];
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        name.isEmpty ||
        targetPrefix is! String ||
        targetPrefix.isEmpty) {
      return null;
    }
    final parent = raw['parent'];
    final createdBy = raw['createdBy'];
    final createdAt = raw['createdAt'];
    return DirectoryAlias(
      id: id,
      name: name,
      targetPrefix: targetPrefix,
      parentPrefix:
          parent is String && parent.isNotEmpty ? parent : defaultParentPrefix,
      createdBy: createdBy is String ? createdBy : null,
      createdAt: createdAt is String ? DateTime.tryParse(createdAt) : null,
    );
  }
}

/// `links.json` 的内存表示。文件不存在或损坏时按空表降级。
class DirectoryAliasTable {
  const DirectoryAliasTable({
    this.version = 1,
    this.aliases = const <DirectoryAlias>[],
  });

  static const currentVersion = 1;

  final int version;
  final List<DirectoryAlias> aliases;

  bool get isEmpty => aliases.isEmpty;

  DirectoryAlias? byId(String id) {
    for (final alias in aliases) {
      if (alias.id == id) return alias;
    }
    return null;
  }

  DirectoryAliasTable copyWith({List<DirectoryAlias>? aliases}) =>
      DirectoryAliasTable(
        version: version,
        aliases: aliases ?? this.aliases,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'links': aliases.map((alias) => alias.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());

  /// 解析失败（非法 JSON 或顶层结构错误）抛出 [FormatException]，
  /// 由调用方按空表降级。[defaultParentPrefix] 为无 `parent` 字段
  /// 存量条目的挂载层级兜底（会话根前缀）。
  static DirectoryAliasTable decode(
    String raw, {
    required String defaultParentPrefix,
  }) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('别名表结构不是对象');
    final links = decoded['links'];
    final aliases = <DirectoryAlias>[];
    if (links is List) {
      for (final item in links) {
        final alias = DirectoryAlias.tryDecode(
          item,
          defaultParentPrefix: defaultParentPrefix,
        );
        if (alias != null) aliases.add(alias);
      }
    }
    final version = decoded['version'];
    return DirectoryAliasTable(
      version: version is num ? version.toInt() : currentVersion,
      aliases: aliases,
    );
  }
}

final Random _idRandom = Random.secure();

String _generateId() {
  final bytes = List<int>.generate(16, (_) => _idRandom.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
