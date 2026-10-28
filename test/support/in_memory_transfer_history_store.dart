import 'package:private_domain_drive_client/features/transfer/domain/transfer_task.dart';
import 'package:private_domain_drive_client/features/transfer/infrastructure/transfer_history_store.dart';

/// 测试用内存历史库：模拟 `finished_at DESC, id DESC` 排序与分页游标，
/// 不依赖 sqflite 平台通道。
class InMemoryTransferHistoryStore extends TransferHistoryStore {
  InMemoryTransferHistoryStore({this.openError});

  final Object? openError;
  final Map<String, TransferTask> rows = <String, TransferTask>{};
  bool _migrationDone = false;
  bool _opened = false;
  int upsertBatches = 0;
  int deleteBatches = 0;
  int loadPageCalls = 0;

  @override
  bool get isOpen => _opened;

  @override
  Future<void> open() async {
    if (openError != null) throw openError!;
    _opened = true;
  }

  @override
  Future<List<TransferTask>> loadPage({
    int limit = 300,
    TransferHistoryCursor? after,
  }) async {
    loadPageCalls++;
    final ordered = sortedRows;
    if (after == null) {
      return ordered.take(limit).toList(growable: false);
    }
    final index = ordered.indexWhere((task) => task.id == after.id);
    if (index >= 0) {
      return ordered.skip(index + 1).take(limit).toList(growable: false);
    }
    return ordered
        .where((task) => _isAfter(task, after))
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<int> countAll() async => rows.length;

  @override
  Future<Map<TransferTaskType, int>> countByType() async {
    final counts = <TransferTaskType, int>{};
    for (final task in rows.values) {
      counts[task.type] = (counts[task.type] ?? 0) + 1;
    }
    return counts;
  }

  @override
  Future<void> upsertAll(Iterable<TransferTask> tasks) async {
    upsertBatches++;
    for (final task in tasks) {
      rows[task.id] = task;
    }
  }

  @override
  Future<void> deleteIds(Iterable<String> ids) async {
    deleteBatches++;
    for (final id in ids) {
      rows.remove(id);
    }
  }

  @override
  Future<void> clear() async {
    rows.clear();
  }

  @override
  Future<bool> isMigrationDone() async => _migrationDone;

  @override
  Future<void> markMigrationDone() async {
    _migrationDone = true;
  }

  @override
  Future<void> prune({
    required DateTime cutoff,
    required int maxRecords,
  }) async {
    rows.removeWhere((_, task) {
      final finishedAt = task.finishedAt;
      return finishedAt != null && finishedAt.isBefore(cutoff);
    });
    final ordered = sortedRows;
    if (ordered.length > maxRecords) {
      for (final task in ordered.skip(maxRecords)) {
        rows.remove(task.id);
      }
    }
  }

  @override
  Future<void> close() async {
    _opened = false;
  }

  /// 直接灌入历史记录，模拟升级前已存在的行。
  void seed(Iterable<TransferTask> tasks) {
    for (final task in tasks) {
      rows[task.id] = task;
    }
  }

  List<TransferTask> get sortedRows {
    final ordered = rows.values.toList(growable: false);
    ordered.sort((a, b) {
      final aFinished = a.finishedAt;
      final bFinished = b.finishedAt;
      if (aFinished != null && bFinished != null) {
        final byTime = bFinished.compareTo(aFinished);
        if (byTime != 0) return byTime;
      } else if (aFinished == null && bFinished != null) {
        return 1;
      } else if (aFinished != null && bFinished == null) {
        return -1;
      }
      return b.id.compareTo(a.id);
    });
    return ordered;
  }

  bool _isAfter(TransferTask task, TransferHistoryCursor cursor) {
    final a = task.finishedAt;
    final b = cursor.finishedAt;
    if (a != null && b != null) {
      if (a.isBefore(b)) return true;
      if (a.isAfter(b)) return false;
      return task.id.compareTo(cursor.id) < 0;
    }
    if (a == null && b != null) return true;
    if (a != null && b == null) return false;
    return task.id.compareTo(cursor.id) < 0;
  }
}
