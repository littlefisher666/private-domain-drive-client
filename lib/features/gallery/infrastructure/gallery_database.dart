import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/photo_entry.dart';

/// 相册本地元数据库：照片索引副本、原图缓存状态、索引元信息。
///
/// 每个账号（bucket + userId）一个独立数据库文件；打开失败视为无索引，
/// 由上层触发全量扫描重建，不阻断应用其他功能。
class GalleryDatabase {
  GalleryDatabase();

  Database? _database;
  String? _openedAccountKey;

  /// 按当前账号打开（必要时切换）数据库。
  Future<Database> open({required String bucket, required String userId}) async {
    final accountKey = '$bucket|$userId';
    if (_database != null && _openedAccountKey == accountKey) {
      return _database!;
    }
    await close();
    final support = await getApplicationSupportDirectory();
    final path =
        '${support.path}${_safe(accountKey)}gallery_meta.db';
    _database = await openDatabase(
      path,
      version: 7,
      onUpgrade: (database, oldVersion, newVersion) async {
        // v2-v4：修复早期版本写坏拍摄时间的索引（EXIF 截断解析、
        // 非标准日期尾巴、HEIC 支持），清空照片条目全量重扫。
        // v5/v6：无 EXIF 时新增文件名/目录日期推断（v6 补充 14 位
        // 连写时间戳），仅重置索引元信息触发增量修复重扫（拍摄
        // 时间正确的条目直接复用）。
        // v7：上传路径补齐同一推断，修复存量上传条目拍摄时间等于
        // 上传时间的问题，同样仅重置索引元信息触发增量重扫。
        if (oldVersion < 4) {
          await database.execute('DROP TABLE IF EXISTS photo_entries');
        }
        await database.execute('DROP TABLE IF EXISTS index_meta');
        await _createIndexTables(database);
      },
      onCreate: (database, version) async {
        await _createIndexTables(database);
        await _createOriginalCacheTable(database);
      },
    );
    _openedAccountKey = accountKey;
    return _database!;
  }

  Future<void> _createIndexTables(Database database) async {
    await database.execute(<String>[
      'CREATE TABLE IF NOT EXISTS photo_entries (',
      'key TEXT PRIMARY KEY,',
      'media INTEGER NOT NULL,',
      'taken_at INTEGER NOT NULL,',
      'size INTEGER NOT NULL,',
      'dir TEXT NOT NULL,',
      'thumb_key TEXT,',
      'mtime INTEGER,',
      'width INTEGER,',
      'height INTEGER,',
      'lat REAL,',
      'lon REAL,',
      'device TEXT',
      ')',
    ].join());
    await database.execute(
        'CREATE INDEX IF NOT EXISTS idx_taken_at ON photo_entries(taken_at)');
    await database.execute(<String>[
      'CREATE TABLE IF NOT EXISTS index_meta (',
      'id INTEGER PRIMARY KEY CHECK (id = 1),',
      'version INTEGER NOT NULL,',
      'scanned_at INTEGER,',
      'needs_repair INTEGER NOT NULL DEFAULT 0',
      ')',
    ].join());
  }

  Future<void> _createOriginalCacheTable(Database database) async {
    await database.execute(<String>[
      'CREATE TABLE IF NOT EXISTS original_cache (',
      'key TEXT PRIMARY KEY,',
      'file_path TEXT NOT NULL,',
      'size INTEGER NOT NULL,',
      'cached_at INTEGER NOT NULL,',
      'last_access INTEGER NOT NULL',
      ')',
    ].join());
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    _openedAccountKey = null;
    try {
      await database?.close();
    } catch (error) {
      debugPrint('[gallery] 关闭元数据库失败: $error');
    }
  }

  Future<PhotoIndexMeta?> readIndexMeta() async {
    final rows = await _database
        ?.query('index_meta', where: 'id = 1', limit: 1);
    if (rows == null || rows.isEmpty) return null;
    final row = rows.first;
    return PhotoIndexMeta(
      version: row['version'] as int,
      scannedAt: row['scanned_at'] is int
          ? DateTime.fromMillisecondsSinceEpoch(row['scanned_at'] as int)
          : null,
      needsRepair: (row['needs_repair'] as int? ?? 0) == 1,
    );
  }

  Future<void> writeIndexMeta(PhotoIndexMeta meta) async {
    await _database?.insert(
      'index_meta',
      meta.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<PhotoEntry>> readAllEntries() async {
    final rows = await _database?.query(
      'photo_entries',
      orderBy: 'taken_at DESC, key DESC',
    );
    if (rows == null) return const <PhotoEntry>[];
    return <PhotoEntry>[for (final row in rows) PhotoEntry.fromRow(row)];
  }

  Future<void> upsertEntries(Iterable<PhotoEntry> entries) async {
    final database = _database;
    if (database == null) return;
    final batch = database.batch();
    for (final entry in entries) {
      batch.insert(
        'photo_entries',
        entry.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> removeEntries(Iterable<String> keys) async {
    final database = _database;
    if (database == null) return;
    final batch = database.batch();
    for (final key in keys) {
      batch.delete(
        'photo_entries',
        where: 'key = ?',
        whereArgs: <Object>[key],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> replaceEntries(Iterable<PhotoEntry> entries) async {
    final database = _database;
    if (database == null) return;
    await database.transaction((txn) async {
      await txn.delete('photo_entries');
      final batch = txn.batch();
      for (final entry in entries) {
        batch.insert('photo_entries', entry.toRow());
      }
      await batch.commit(noResult: true);
    });
  }

  Future<bool> hasOriginalCache(String key) async {
    final rows = await _database
        ?.query('original_cache', where: 'key = ?', whereArgs: <Object>[key], limit: 1);
    return rows != null && rows.isNotEmpty;
  }

  Future<Map<String, String>> readAllCachedPaths() async {
    final rows = await _database?.query('original_cache');
    if (rows == null) return const <String, String>{};
    return <String, String>{
      for (final row in rows)
        row['key'] as String: row['file_path'] as String,
    };
  }

  Future<int> cachedTotalSize() async {
    final result = await _database
        ?.rawQuery('SELECT COALESCE(SUM(size), 0) AS total FROM original_cache');
    if (result == null || result.isEmpty) return 0;
    return (result.first['total'] as num?)?.toInt() ?? 0;
  }

  Future<OriginalCacheRecord?> readCacheRecord(String key) async {
    final rows = await _database
        ?.query('original_cache', where: 'key = ?', whereArgs: <Object>[key], limit: 1);
    if (rows == null || rows.isEmpty) return null;
    final row = rows.first;
    return OriginalCacheRecord(
      key: row['key'] as String,
      filePath: row['file_path'] as String,
      size: row['size'] as int,
      cachedAt: DateTime.fromMillisecondsSinceEpoch(row['cached_at'] as int),
      lastAccess: DateTime.fromMillisecondsSinceEpoch(row['last_access'] as int),
    );
  }

  Future<void> writeCacheRecord({
    required String key,
    required String filePath,
    required int size,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _database?.insert(
      'original_cache',
      <String, Object?>{
        'key': key,
        'file_path': filePath,
        'size': size,
        'cached_at': now,
        'last_access': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> touchCacheRecord(String key) async {
    await _database?.update(
      'original_cache',
      <String, Object?>{'last_access': DateTime.now().millisecondsSinceEpoch},
      where: 'key = ?',
      whereArgs: <Object>[key],
    );
  }

  Future<void> removeCacheRecords(Iterable<String> keys) async {
    final database = _database;
    if (database == null) return;
    final batch = database.batch();
    for (final key in keys) {
      batch.delete(
        'original_cache',
        where: 'key = ?',
        whereArgs: <Object>[key],
      );
    }
    await batch.commit(noResult: true);
  }

  /// 返回按最后访问时间从旧到新排序的缓存记录（LRU 清理用）。
  Future<List<OriginalCacheRecord>> readCacheRecordsByLru() async {
    final rows = await _database
        ?.query('original_cache', orderBy: 'last_access ASC');
    if (rows == null) return const <OriginalCacheRecord>[];
    return <OriginalCacheRecord>[
      for (final row in rows)
        OriginalCacheRecord(
          key: row['key'] as String,
          filePath: row['file_path'] as String,
          size: row['size'] as int,
          cachedAt: DateTime.fromMillisecondsSinceEpoch(row['cached_at'] as int),
          lastAccess:
              DateTime.fromMillisecondsSinceEpoch(row['last_access'] as int),
        ),
    ];
  }

  /// 返回最后访问时间早于截止时间的记录。
  Future<List<OriginalCacheRecord>> readExpiredCacheRecords(
      DateTime cutoff) async {
    final rows = await _database?.query(
      'original_cache',
      where: 'last_access < ?',
      whereArgs: <Object>[cutoff.millisecondsSinceEpoch],
    );
    if (rows == null) return const <OriginalCacheRecord>[];
    return <OriginalCacheRecord>[
      for (final row in rows)
        OriginalCacheRecord(
          key: row['key'] as String,
          filePath: row['file_path'] as String,
          size: row['size'] as int,
          cachedAt: DateTime.fromMillisecondsSinceEpoch(row['cached_at'] as int),
          lastAccess:
              DateTime.fromMillisecondsSinceEpoch(row['last_access'] as int),
        ),
    ];
  }
}

class OriginalCacheRecord {
  const OriginalCacheRecord({
    required this.key,
    required this.filePath,
    required this.size,
    required this.cachedAt,
    required this.lastAccess,
  });

  final String key;
  final String filePath;
  final int size;
  final DateTime cachedAt;
  final DateTime lastAccess;
}

String _safe(String accountKey) {
  final builder = StringBuffer();
  for (final code in accountKey.codeUnits) {
    if (code >= 48 && code <= 57 ||
        code >= 65 && code <= 90 ||
        code >= 97 && code <= 122) {
      builder.writeCharCode(code);
    } else {
      builder.write(code.toRadixString(16).padLeft(2, '0'));
    }
  }
  return '${builder.toString()}_';
}
