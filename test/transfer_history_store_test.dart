import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/transfer/domain/transfer_task.dart';
import 'package:private_domain_drive_client/features/transfer/infrastructure/transfer_history_store.dart';

import 'support/in_memory_transfer_history_store.dart';

void main() {
  group('TransferHistoryStore 行映射', () {
    final queuedAt = DateTime.utc(2026, 10, 1, 8);
    final finishedAt = DateTime.utc(2026, 10, 1, 8, 5);
    final task = TransferTask(
      id: 'upload-1',
      name: '归档.zip',
      type: TransferTaskType.upload,
      status: TransferTaskStatus.success,
      progress: 1,
      message: '已完成',
      target: '/共享空间/归档.zip',
      targetDir: '/共享空间/',
      sourcePath: '/tmp/归档.zip',
      batchId: 'batch-1',
      transferredBytes: 4096,
      totalBytes: 4096,
      bytesPerSecond: 1024,
      error: null,
      queuedAt: queuedAt,
      startedAt: queuedAt,
      lastStartedAt: queuedAt,
      finishedAt: finishedAt,
      activeDurationMs: 4000,
      totalTransferredBytes: 4096,
      attemptCount: 2,
    );

    test('任务写入 snake_case 列且时间戳为 UTC 毫秒', () {
      final row = TransferHistoryStore.rowFromTask(task);

      expect(row['id'], 'upload-1');
      expect(row['type'], 'upload');
      expect(row['status'], 'success');
      expect(row['target_dir'], '/共享空间/');
      expect(row['source_path'], '/tmp/归档.zip');
      expect(row['batch_id'], 'batch-1');
      expect(row['queued_at'], queuedAt.millisecondsSinceEpoch);
      expect(row['finished_at'], finishedAt.millisecondsSinceEpoch);
      expect(row['active_duration_ms'], 4000);
      expect(row['total_transferred_bytes'], 4096);
      expect(row['attempt_count'], 2);
    });

    test('行数据还原任务且保留时间线与统计字段', () {
      final restored = TransferHistoryStore.taskFromRow(
        TransferHistoryStore.rowFromTask(task),
      );

      expect(restored, isNotNull);
      expect(restored!.id, task.id);
      expect(restored.name, task.name);
      expect(restored.type, task.type);
      expect(restored.status, task.status);
      expect(restored.targetDir, task.targetDir);
      expect(restored.sourcePath, task.sourcePath);
      expect(restored.batchId, task.batchId);
      expect(restored.queuedAt!.millisecondsSinceEpoch,
          queuedAt.millisecondsSinceEpoch);
      expect(restored.finishedAt!.millisecondsSinceEpoch,
          finishedAt.millisecondsSinceEpoch);
      expect(restored.activeDurationMs, 4000);
      expect(restored.totalTransferredBytes, 4096);
      expect(restored.attemptCount, 2);
    });

    test('缺失可空列时还原为默认值', () {
      final restored = TransferHistoryStore.taskFromRow(<String, Object?>{
        'id': 'download-1',
        'name': 'a.txt',
        'type': 'download',
        'status': 'failed',
        'progress': 0.5,
      });

      expect(restored, isNotNull);
      expect(restored!.attemptCount, 1);
      expect(restored.activeDurationMs, 0);
      expect(restored.queuedAt, isNull);
      expect(restored.finishedAt, isNull);
      expect(restored.error, isNull);
    });

    test('基础列非法时返回 null', () {
      expect(
        TransferHistoryStore.taskFromRow(<String, Object?>{'id': 'x'}),
        isNull,
      );
    });

    test('游标取自任务结束时间与 id', () {
      final cursor = TransferHistoryCursor.fromTask(task);

      expect(cursor.id, task.id);
      expect(cursor.finishedAt, finishedAt);
    });
  });

  group('内存历史库分页语义', () {
    TransferTask finished(String id, DateTime at) => TransferTask(
          id: id,
          name: '$id.txt',
          type: TransferTaskType.download,
          status: TransferTaskStatus.success,
          progress: 1,
          finishedAt: at,
        );

    test('按结束时间与 id 倒序翻页不重不漏', () async {
      final store = InMemoryTransferHistoryStore();
      final base = DateTime.utc(2026, 10, 1);
      final tasks = <TransferTask>[
        finished('a', base.add(const Duration(minutes: 1))),
        finished('b', base.add(const Duration(minutes: 2))),
        finished('c', base.add(const Duration(minutes: 3))),
        finished('d', base.add(const Duration(minutes: 3))),
        finished('e', base.add(const Duration(minutes: 4))),
      ];
      store.seed(tasks);

      final loaded = <TransferTask>[];
      TransferHistoryCursor? cursor;
      while (true) {
        final page = await store.loadPage(limit: 2, after: cursor);
        loaded.addAll(page);
        if (page.length < 2) break;
        cursor = TransferHistoryCursor.fromTask(page.last);
      }

      expect(loaded.map((task) => task.id).toList(),
          <String>['e', 'd', 'c', 'b', 'a']);
      expect(loaded.map((task) => task.id).toSet(), hasLength(5));
    });

    test('排序不在完成时间相同的记录间重复或遗漏', () async {
      final store = InMemoryTransferHistoryStore();
      final at = DateTime.utc(2026, 10, 1);
      final tasks = <TransferTask>[
        for (var index = 0; index < 7; index++) finished('id-$index', at),
      ];
      store.seed(tasks);

      final loaded = <TransferTask>[];
      TransferHistoryCursor? cursor;
      while (true) {
        final page = await store.loadPage(limit: 3, after: cursor);
        loaded.addAll(page);
        if (page.length < 3) break;
        cursor = TransferHistoryCursor.fromTask(page.last);
      }

      expect(loaded.map((task) => task.id).toList(),
          <String>['id-6', 'id-5', 'id-4', 'id-3', 'id-2', 'id-1', 'id-0']);
    });
  });
}
