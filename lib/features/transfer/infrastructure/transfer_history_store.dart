import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/transfer_task.dart';

/// 分页游标：按结束时间倒序、id 倒序翻页，避免偏移分页在新增终态
/// 记录时重复或遗漏。
class TransferHistoryCursor {
  const TransferHistoryCursor({required this.finishedAt, required this.id});

  final DateTime? finishedAt;
  final String id;

  factory TransferHistoryCursor.fromTask(TransferTask task) {
    return TransferHistoryCursor(finishedAt: task.finishedAt, id: task.id);
  }
}

/// 传输历史 SQLite 存储：终态任务按 id 增量 upsert，不再整表重写。
///
/// 默认使用 `sqflite` 打开应用支持目录下的 `transfer_history.db`；
/// 路径与数据库工厂可注入，方法均可覆写，便于测试使用内存实现。
class TransferHistoryStore {
  TransferHistoryStore({
    DatabaseFactory? databaseFactory,
    Future<String> Function()? databasePathProvider,
  })  : _databaseFactory = databaseFactory,
        _databasePathProvider = databasePathProvider;

  static const table = 'transfer_history';
  static const metaTable = 'transfer_history_meta';
  static const migrationKey = 'legacy_shared_preferences_migrated';
  static const schemaVersion = 1;

  final DatabaseFactory? _databaseFactory;
  final Future<String> Function()? _databasePathProvider;

  Database? _database;
  Future<Database>? _opening;

  bool get isOpen => _database != null;

  Future<void> open() async {
    if (_database != null) return;
    final opening = _opening;
    if (opening != null) {
      await opening;
      return;
    }
    final future = _openDatabase();
    _opening = future;
    try {
      _database = await future;
    } finally {
      _opening = null;
    }
  }

  Future<Database> _openDatabase() async {
    final factory = _databaseFactory ?? databaseFactory;
    final path = await _resolvePath();
    return factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (database, version) async {
          await _createSchema(database);
        },
      ),
    );
  }

  Future<String> _resolvePath() async {
    final provider = _databasePathProvider;
    if (provider != null) return provider();
    final support = await getApplicationSupportDirectory();
    return '${support.path}${Platform.pathSeparator}transfer_history.db';
  }

  Future<void> _createSchema(Database database) async {
    await database.execute(<String>[
      'CREATE TABLE IF NOT EXISTS $table (',
      'id TEXT PRIMARY KEY,',
      'name TEXT NOT NULL,',
      'type TEXT NOT NULL,',
      'status TEXT NOT NULL,',
      'progress REAL NOT NULL,',
      'message TEXT,',
      'target TEXT,',
      'target_dir TEXT,',
      'source_path TEXT,',
      'batch_id TEXT,',
      'transferred_bytes INTEGER NOT NULL DEFAULT 0,',
      'total_bytes INTEGER,',
      'bytes_per_second REAL,',
      'error TEXT,',
      'queued_at INTEGER,',
      'started_at INTEGER,',
      'last_started_at INTEGER,',
      'finished_at INTEGER,',
      'active_duration_ms INTEGER NOT NULL DEFAULT 0,',
      'total_transferred_bytes INTEGER NOT NULL DEFAULT 0,',
      'attempt_count INTEGER NOT NULL DEFAULT 1',
      ')',
    ].join());
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_transfer_history_finished_at '
      'ON $table(finished_at DESC)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS idx_transfer_history_type_finished_at '
      'ON $table(type, finished_at DESC)',
    );
    await database.execute(<String>[
      'CREATE TABLE IF NOT EXISTS $metaTable (',
      'key TEXT PRIMARY KEY,',
      'value TEXT NOT NULL',
      ')',
    ].join());
  }

  /// 按结束时间倒序、id 倒序读取一页；[after] 为上一页最后一条记录。
  /// 缺失结束时间的旧记录排在末尾。
  Future<List<TransferTask>> loadPage({
    int limit = 300,
    TransferHistoryCursor? after,
  }) async {
    final database = _database;
    if (database == null) return const <TransferTask>[];
    String? where;
    List<Object?>? whereArgs;
    if (after != null) {
      if (after.finishedAt != null) {
        final boundary = after.finishedAt!.millisecondsSinceEpoch;
        where = '(finished_at < ? OR (finished_at = ? AND id < ?) '
            'OR finished_at IS NULL)';
        whereArgs = <Object?>[boundary, boundary, after.id];
      } else {
        where = 'finished_at IS NULL AND id < ?';
        whereArgs = <Object?>[after.id];
      }
    }
    final rows = await database.query(
      table,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'finished_at DESC, id DESC',
      limit: limit,
    );
    final tasks = <TransferTask>[];
    for (final row in rows) {
      final task = taskFromRow(row);
      if (task != null) tasks.add(task);
    }
    return tasks;
  }

  Future<int> countAll() async {
    final database = _database;
    if (database == null) return 0;
    final rows = await database.rawQuery('SELECT COUNT(*) AS count FROM $table');
    return (rows.first['count'] as num?)?.toInt() ?? 0;
  }

  Future<Map<TransferTaskType, int>> countByType() async {
    final database = _database;
    if (database == null) return const <TransferTaskType, int>{};
    final rows = await database.rawQuery(
      'SELECT type, COUNT(*) AS count FROM $table GROUP BY type',
    );
    final counts = <TransferTaskType, int>{};
    for (final row in rows) {
      TransferTaskType? type;
      for (final value in TransferTaskType.values) {
        if (value.name == row['type']) {
          type = value;
          break;
        }
      }
      if (type == null) continue;
      counts[type] = (row['count'] as num?)?.toInt() ?? 0;
    }
    return counts;
  }

  Future<void> upsertAll(Iterable<TransferTask> tasks) async {
    final database = _database;
    if (database == null) return;
    final values = tasks.toList(growable: false);
    if (values.isEmpty) return;
    await database.transaction((txn) async {
      final batch = txn.batch();
      for (final task in values) {
        batch.insert(
          table,
          rowFromTask(task),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> deleteIds(Iterable<String> ids) async {
    final database = _database;
    if (database == null) return;
    final values = ids.toList(growable: false);
    if (values.isEmpty) return;
    await database.transaction((txn) async {
      final batch = txn.batch();
      for (final id in values) {
        batch.delete(table, where: 'id = ?', whereArgs: <Object>[id]);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> clear() async {
    await _database?.delete(table);
  }

  Future<bool> isMigrationDone() async {
    final database = _database;
    if (database == null) return false;
    final rows = await database.query(
      metaTable,
      where: 'key = ?',
      whereArgs: <Object>[migrationKey],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> markMigrationDone() async {
    await _database?.insert(
      metaTable,
      <String, Object?>{'key': migrationKey, 'value': '1'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 先删除结束时间早于 [cutoff] 的记录，再按结束时间倒序保留最多
  /// [maxRecords] 条。
  Future<void> prune({
    required DateTime cutoff,
    required int maxRecords,
  }) async {
    final database = _database;
    if (database == null) return;
    await database.transaction((txn) async {
      await txn.delete(
        table,
        where: 'finished_at IS NOT NULL AND finished_at < ?',
        whereArgs: <Object>[cutoff.millisecondsSinceEpoch],
      );
      await txn.rawDelete(
        'DELETE FROM $table WHERE id NOT IN ('
        'SELECT id FROM $table ORDER BY finished_at DESC, id DESC LIMIT ?)',
        <Object>[maxRecords],
      );
    });
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    try {
      await database?.close();
    } catch (_) {
      // 关闭失败不影响后续流程。
    }
  }

  static Map<String, Object?> rowFromTask(TransferTask task) {
    return <String, Object?>{
      'id': task.id,
      'name': task.name,
      'type': task.type.name,
      'status': task.status.name,
      'progress': task.progress,
      'message': task.message,
      'target': task.target,
      'target_dir': task.targetDir,
      'source_path': task.sourcePath,
      'batch_id': task.batchId,
      'transferred_bytes': task.transferredBytes,
      'total_bytes': task.totalBytes,
      'bytes_per_second': task.bytesPerSecond,
      'error': task.error,
      'queued_at': task.queuedAt?.toUtc().millisecondsSinceEpoch,
      'started_at': task.startedAt?.toUtc().millisecondsSinceEpoch,
      'last_started_at':
          task.lastStartedAt?.toUtc().millisecondsSinceEpoch,
      'finished_at': task.finishedAt?.toUtc().millisecondsSinceEpoch,
      'active_duration_ms': task.activeDurationMs,
      'total_transferred_bytes': task.totalTransferredBytes,
      'attempt_count': task.attemptCount,
    };
  }

  static TransferTask? taskFromRow(Map<String, Object?> row) {
    return TransferTask.fromJson(<String, Object?>{
      'id': row['id'],
      'name': row['name'],
      'type': row['type'],
      'status': row['status'],
      'progress': row['progress'],
      'message': row['message'],
      'target': row['target'],
      'targetDir': row['target_dir'],
      'sourcePath': row['source_path'],
      'batchId': row['batch_id'],
      'transferredBytes': row['transferred_bytes'],
      'totalBytes': row['total_bytes'],
      'bytesPerSecond': row['bytes_per_second'],
      'error': row['error'],
      'queuedAt': row['queued_at'],
      'startedAt': row['started_at'],
      'lastStartedAt': row['last_started_at'],
      'finishedAt': row['finished_at'],
      'activeDurationMs': row['active_duration_ms'],
      'totalTransferredBytes': row['total_transferred_bytes'],
      'attemptCount': row['attempt_count'],
    });
  }
}
