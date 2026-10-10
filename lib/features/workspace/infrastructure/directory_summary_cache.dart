import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'oss_client.dart';

/// 目录统计本地缓存：按目录路径持久化条目数与最新更新时间。
///
/// 每个账号（bucket + userId）一个独立数据库文件；所有读写异常均吞错
/// 降级为无缓存，不影响目录浏览与统计功能本身。
class DirectorySummaryCache {
  Database? _database;
  String? _openedAccountKey;

  Future<Database?> _open(String accountKey) async {
    if (_database != null && _openedAccountKey == accountKey) {
      return _database;
    }
    await close();
    try {
      final support = await getApplicationSupportDirectory();
      final path =
          '${support.path}${_safe(accountKey)}directory_summaries.db';
      final database = await openDatabase(
        path,
        version: 1,
        onCreate: (database, version) async {
          await database.execute(<String>[
            'CREATE TABLE IF NOT EXISTS directory_summaries (',
            'path TEXT PRIMARY KEY,',
            'item_count INTEGER NOT NULL,',
            'updated_at INTEGER,',
            'fetched_at INTEGER NOT NULL',
            ')',
          ].join());
        },
      );
      _database = database;
      _openedAccountKey = accountKey;
      return database;
    } catch (error) {
      debugPrint('[directory-summary] 缓存库打开失败: $error');
      return null;
    }
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    _openedAccountKey = null;
    try {
      await database?.close();
    } catch (error) {
      debugPrint('[directory-summary] 关闭缓存库失败: $error');
    }
  }

  /// 批量读取目录统计；未命中的路径不出现在结果中。
  Future<Map<String, DirectorySummary>> read(
    Iterable<String> paths, {
    required String accountKey,
  }) async {
    try {
      final database = await _open(accountKey);
      if (database == null) return const <String, DirectorySummary>{};
      final keys = paths.toSet().toList(growable: false);
      final result = <String, DirectorySummary>{};
      for (var offset = 0; offset < keys.length; offset += 500) {
        final batch = keys.sublist(
          offset,
          offset + 500 > keys.length ? keys.length : offset + 500,
        );
        final placeholders = List.filled(batch.length, '?').join(',');
        final rows = await database.query(
          'directory_summaries',
          where: 'path IN ($placeholders)',
          whereArgs: batch,
        );
        for (final row in rows) {
          final path = row['path'] as String?;
          final itemCount = row['item_count'] as int?;
          if (path == null || itemCount == null) continue;
          final updatedAtMillis = row['updated_at'] as int?;
          result[path] = DirectorySummary(
            itemCount: itemCount,
            updatedAt: updatedAtMillis == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(updatedAtMillis),
          );
        }
      }
      return result;
    } catch (_) {
      return const <String, DirectorySummary>{};
    }
  }

  Future<void> write(
    String path,
    DirectorySummary summary, {
    required String accountKey,
  }) async {
    try {
      final database = await _open(accountKey);
      if (database == null) return;
      await database.insert(
        'directory_summaries',
        <String, Object?>{
          'path': path,
          'item_count': summary.itemCount,
          'updated_at': summary.updatedAt?.millisecondsSinceEpoch,
          'fetched_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {
      // 缓存写入失败不影响统计展示。
    }
  }

  /// 增量修正：计数取不小于 0 的累加结果，更新时间取新旧较大值。
  Future<void> adjust(
    String path, {
    required String accountKey,
    required int itemCountDelta,
    DateTime? updatedAt,
  }) async {
    try {
      final database = await _open(accountKey);
      if (database == null) return;
      final rows = await database.query(
        'directory_summaries',
        where: 'path = ?',
        whereArgs: <Object>[path],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final row = rows.first;
      final currentCount = row['item_count'] as int? ?? 0;
      final nextCount = (currentCount + itemCountDelta).clamp(0, 1 << 31);
      final currentUpdatedAt = row['updated_at'] as int?;
      final nextUpdatedAt = updatedAt?.millisecondsSinceEpoch;
      await database.update(
        'directory_summaries',
        <String, Object?>{
          'item_count': nextCount,
          'updated_at': (currentUpdatedAt != null &&
                  nextUpdatedAt != null &&
                  currentUpdatedAt > nextUpdatedAt)
              ? currentUpdatedAt
              : nextUpdatedAt ?? currentUpdatedAt,
          'fetched_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'path = ?',
        whereArgs: <Object>[path],
      );
    } catch (_) {
      // 缓存修正失败由后台校准兜底。
    }
  }

  Future<void> invalidate(String path, {required String accountKey}) async {
    try {
      final database = await _open(accountKey);
      if (database == null) return;
      await database.delete(
        'directory_summaries',
        where: 'path = ?',
        whereArgs: <Object>[path],
      );
    } catch (_) {
      // 缓存删除失败无副作用，行内容随后台校准覆盖。
    }
  }
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
