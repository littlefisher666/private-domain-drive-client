import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/transfer/application/transfer_queue.dart';
import 'package:private_domain_drive_client/features/transfer/domain/transfer_task.dart';
import 'package:private_domain_drive_client/features/transfer/infrastructure/transfer_history_store.dart';
import 'package:private_domain_drive_client/shared/transfer_keepalive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_transfer_history_store.dart';

void main() {
  group('传输历史分页与计数', () {
    test('启动加载首页 300 条，滚动加载追加且不重不漏', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = InMemoryTransferHistoryStore();
      final base = DateTime.utc(2026, 10, 1);
      store.seed(<TransferTask>[
        for (var index = 0; index < 301; index++)
          _finishedTask(
            'download-$index',
            finishedAt: base.add(Duration(minutes: index)),
            type: index.isEven
                ? TransferTaskType.upload
                : TransferTaskType.download,
          ),
      ]);
      final queue = await _restore(store);
      addTearDown(queue.dispose);

      expect(queue.tasks, hasLength(300));
      expect(queue.historyHasMore, isTrue);
      expect(queue.historyLoading, isFalse);
      expect(queue.historyCountsListenable.value!.total, 301);
      expect(queue.historyCountsListenable.value!.upload, 151);
      expect(queue.historyCountsListenable.value!.download, 150);
      expect(queue.typeCounts.total, 301);

      await queue.loadMoreHistory();

      expect(queue.tasks, hasLength(301));
      expect(queue.tasks.map((task) => task.id).toSet(), hasLength(301));
      expect(queue.historyHasMore, isFalse);
      expect(store.loadPageCalls, 2);
      // 末尾是结束时间最早的记录，首页与第二页之间无重复。
      expect(queue.tasks.last.id, 'download-0');
      expect(queue.historyCountsListenable.value!.total, 301);

      // 没有更多历史时不再发起查询。
      await queue.loadMoreHistory();
      expect(store.loadPageCalls, 2);
    });

    test('历史计数包含未加载分页与内存中未结束任务', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = InMemoryTransferHistoryStore();
      final base = DateTime.utc(2026, 10, 1);
      store.seed(<TransferTask>[
        for (var index = 0; index < 301; index++)
          _finishedTask('download-$index',
              finishedAt: base.add(Duration(minutes: index))),
      ]);
      final queue = await _restore(store);
      addTearDown(queue.dispose);

      queue.setTasks(<TransferTask>[
        ...queue.tasks,
        const TransferTask(
          id: 'pending-upload',
          name: '等待上传.txt',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.pending,
          progress: 0,
        ),
      ]);

      // 301 条历史（含未加载的 1 条）+ 1 条未结束上传。
      expect(queue.tasks, hasLength(301));
      expect(queue.typeCounts.total, 302);
      expect(queue.typeCounts.upload, 1);
      expect(queue.typeCounts.download, 301);
    });

    test('历史库不可用时计数回退为内存任务', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store =
          InMemoryTransferHistoryStore(openError: StateError('database down'));
      final queue = await _restore(store);
      addTearDown(queue.dispose);
      queue.setTasks(const <TransferTask>[
        TransferTask(
          id: 'upload-1',
          name: 'a.txt',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.success,
          progress: 1,
        ),
      ]);

      expect(queue.historyCountsListenable.value, isNull);
      expect(queue.typeCounts.upload, 1);
      expect(queue.typeCounts.download, 0);
    });
  });

  group('传输历史写入', () {
    test('批量终态合并为单次 upsert', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = InMemoryTransferHistoryStore();
      final queue = await _restore(store);
      addTearDown(queue.dispose);
      final base = DateTime.utc(2026, 10, 1);

      queue.setTasks(<TransferTask>[
        for (var index = 0; index < 50; index++)
          _finishedTask('upload-$index',
              finishedAt: base.add(Duration(seconds: index))),
      ]);
      await queue.flushHistory();

      expect(store.upsertBatches, 1);
      expect(store.rows, hasLength(50));
    });

    test('清除已结束任务同步删除历史行', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = InMemoryTransferHistoryStore()
        ..seed(<TransferTask>[
          _finishedTask('download-1', finishedAt: DateTime.utc(2026, 10, 1)),
        ]);
      final queue = await _restore(store);
      addTearDown(queue.dispose);

      queue.setTasks(const <TransferTask>[]);
      await _waitUntil(
        () =>
            store.rows.isEmpty &&
            queue.historyCountsListenable.value?.total == 0,
        '历史行删除或计数刷新未完成',
      );

      expect(store.deleteBatches, 1);
      expect(queue.historyCountsListenable.value!.total, 0);
    });

    test('失败任务重试移出历史，成功后重新写入', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final finishedAt = DateTime.utc(2026, 10, 1, 8);
      final failed = TransferTask(
        id: 'download-1',
        name: '资料.pdf',
        type: TransferTaskType.download,
        status: TransferTaskStatus.failed,
        progress: 0.4,
        finishedAt: finishedAt,
        error: '网络中断',
        attemptCount: 2,
      );
      final store = InMemoryTransferHistoryStore()..seed(<TransferTask>[failed]);
      final queue = await _restore(store);
      addTearDown(queue.dispose);

      expect(queue.tasks.single.status, TransferTaskStatus.failed);
      expect(queue.historyCountsListenable.value!.download, 1);

      queue.replaceTask(
        failed.id,
        (task) => task.copyWith(
          status: TransferTaskStatus.pending,
          progress: 0,
          message: '重新开始',
          clearFinishedAt: true,
        ),
      );
      await _waitUntil(
        () =>
            store.rows.isEmpty &&
            queue.historyCountsListenable.value?.total == 0,
        '重试后历史未移除',
      );

      queue.replaceTask(
        failed.id,
        (task) => task.copyWith(
          status: TransferTaskStatus.success,
          progress: 1,
          message: '已完成',
          finishedAt: DateTime.utc(2026, 10, 1, 9),
        ),
      );
      await _waitUntil(
        () =>
            store.rows[failed.id]?.status == TransferTaskStatus.success &&
            queue.historyCountsListenable.value?.download == 1,
        '成功后历史未重新写入',
      );

      expect(store.rows[failed.id]!.attemptCount, 2);
    });

    test('写入失败时保留待写记录并在下次重试', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = _FailingUpsertStore()..failUpserts = true;
      final queue = await _restore(store);
      addTearDown(queue.dispose);

      queue.setTasks(<TransferTask>[
        _finishedTask('upload-1', finishedAt: DateTime.utc(2026, 10, 1)),
      ]);
      await queue.flushHistory();
      expect(store.rows, isEmpty);

      store.failUpserts = false;
      await queue.flushHistory();
      await _waitUntil(() => store.rows.isNotEmpty, '重试后历史仍未写入');
      expect(store.rows, hasLength(1));
    });

    test('启动时源文件丢失的失败任务补写结束时间与历史', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'upload_pending:v1': jsonEncode(<Map<String, Object?>>[
          TransferTask(
            id: 'upload-lost',
            name: '丢失.txt',
            type: TransferTaskType.upload,
            status: TransferTaskStatus.running,
            progress: 0.3,
            target: '/共享空间/丢失.txt',
            targetDir: '/共享空间/',
            sourcePath: '/nonexistent/pdd/丢失.txt',
            queuedAt: DateTime.utc(2026, 10, 1, 8),
          ).toJson(),
        ]),
      });
      final store = InMemoryTransferHistoryStore();
      final queue = await _restore(store);
      addTearDown(queue.dispose);

      final task = queue.tasks.single;
      expect(task.status, TransferTaskStatus.failed);
      expect(task.error, '源文件已丢失');
      expect(task.finishedAt, isNotNull);
      expect(store.rows.keys, contains('upload-lost'));
      expect(store.rows['upload-lost']!.finishedAt, isNotNull);
      expect(queue.historyCountsListenable.value!.upload, 1);
    });
  });

  group('传输历史保留策略', () {
    test('启动清理超过 90 天的记录，保留近期与缺失结束时间记录', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final now = DateTime.now();
      final store = _RecordingStore();
      store.seed(<TransferTask>[
        _finishedTask('old', finishedAt: now.subtract(const Duration(days: 91))),
        _finishedTask('recent',
            finishedAt: now.subtract(const Duration(days: 89))),
        TransferTask(
          id: 'no-finish',
          name: '旧任务.txt',
          type: TransferTaskType.download,
          status: TransferTaskStatus.success,
          progress: 1,
        ),
      ]);
      final queue = await _restore(store);
      addTearDown(queue.dispose);

      expect(store.rows.keys, isNot(contains('old')));
      expect(store.rows.keys, containsAll(<String>['recent', 'no-finish']));
      expect(queue.tasks, hasLength(2));
      expect(store.pruneCalls, isNotEmpty);
      expect(store.pruneCalls.first.maxRecords, TransferQueue.historyMaxRecords);
      final expectedCutoff =
          now.subtract(const Duration(days: TransferQueue.historyRetentionDays));
      expect(
        store.pruneCalls.first.cutoff
            .difference(expectedCutoff)
            .inMinutes
            .abs(),
        lessThanOrEqualTo(1),
      );
    });

    test('超过 20000 条按结束时间保留最新记录', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final base = DateTime.utc(2026, 10, 1);
      final store = InMemoryTransferHistoryStore();
      store.seed(<TransferTask>[
        for (var index = 0; index < 20005; index++)
          _finishedTask('download-$index',
              finishedAt: base.add(Duration(seconds: index))),
      ]);
      final queue = await _restore(store);
      addTearDown(queue.dispose);

      expect(store.rows, hasLength(TransferQueue.historyMaxRecords));
      expect(store.rows.keys, isNot(contains('download-0')));
      expect(store.rows.keys, isNot(contains('download-4')));
      expect(store.rows.keys, contains('download-5'));
      expect(store.rows.keys, contains('download-20004'));
    });

    test('单批 300 条新记录不会触发超限淘汰', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final base = DateTime.utc(2026, 10, 1);
      final store = InMemoryTransferHistoryStore()
        ..seed(<TransferTask>[
          for (var index = 0; index < 250; index++)
            _finishedTask('download-$index',
                finishedAt: base.add(Duration(minutes: index))),
        ]);
      final queue = await _restore(store);
      addTearDown(queue.dispose);

      queue.setTasks(<TransferTask>[
        ...queue.tasks,
        for (var index = 0; index < 50; index++)
          _finishedTask('new-$index',
              finishedAt: base.add(Duration(days: 1, seconds: index))),
      ]);
      await queue.flushHistory();

      expect(store.rows, hasLength(300));
      expect(store.rows.keys, containsAll(<String>['download-0', 'new-0']));
    });
  });

  group('旧 SharedPreferences 历史迁移', () {
    test('损坏 JSON 只标记一次完成，不阻断启动', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'transfer_history:v1': '{not-a-json',
      });
      final store = InMemoryTransferHistoryStore();
      final queue = await _restore(store);
      addTearDown(queue.dispose);

      expect(store.rows, isEmpty);
      expect(await store.isMigrationDone(), isTrue);
      expect(queue.tasks, isEmpty);
    });

    test('缺失字段记录兼容导入，未结束任务不进入历史', () async {
      final micros = DateTime.utc(2026, 9, 1, 8).microsecondsSinceEpoch;
      SharedPreferences.setMockInitialValues(<String, Object>{
        'transfer_history:v1': jsonEncode(<Object>[
          <String, Object?>{
            'id': 'download-$micros-0',
            'name': '旧记录.jpg',
            'type': 'download',
            'status': 'success',
            'progress': 1,
          },
          <String, Object?>{
            'id': 'upload-pending-1',
            'name': '未完成任务.txt',
            'type': 'upload',
            'status': 'running',
            'progress': 0.5,
          },
          <String, Object?>{'id': 'broken'},
        ]),
      });
      final store = InMemoryTransferHistoryStore();
      final queue = await _restore(store);
      addTearDown(queue.dispose);

      expect(store.rows.keys, <String>['download-$micros-0']);
      final imported = store.rows.values.single;
      expect(imported.queuedTime, isNotNull);
      expect(imported.queuedTime!.year, 2026);
      expect(imported.attemptCount, 1);
      expect(await store.isMigrationDone(), isTrue);
      expect(store.upsertBatches, 1);
    });

    test('导入失败不写标记，下次启动重新导入', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'transfer_history:v1': jsonEncode(<Map<String, Object?>>[
          _finishedTask('download-1', finishedAt: DateTime.utc(2026, 10, 1))
              .toJson(),
        ]),
      });
      final store = _FailingUpsertStore()..failUpserts = true;
      final first = await _restore(store);
      first.dispose();

      expect(await store.isMigrationDone(), isFalse);
      expect(store.rows, isEmpty);

      store.failUpserts = false;
      final second = await _restore(store);
      addTearDown(second.dispose);

      expect(await store.isMigrationDone(), isTrue);
      expect(store.rows, hasLength(1));
    });
  });
}

TransferTask _finishedTask(
  String id, {
  required DateTime finishedAt,
  TransferTaskType type = TransferTaskType.download,
}) {
  return TransferTask(
    id: id,
    name: '$id.txt',
    type: type,
    status: TransferTaskStatus.success,
    progress: 1,
    finishedAt: finishedAt,
  );
}

Future<TransferQueue> _restore(
  TransferHistoryStore store, {
  SharedPreferences? preferences,
}) async {
  final queue = TransferQueue(
    transferKeepalive: const NoopTransferKeepaliveService(),
    historyStore: store,
  );
  await queue.restore(preferences ?? await SharedPreferences.getInstance());
  return queue;
}

Future<void> _waitUntil(bool Function() condition, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _RecordingStore extends InMemoryTransferHistoryStore {
  final List<({DateTime cutoff, int maxRecords})> pruneCalls =
      <({DateTime cutoff, int maxRecords})>[];

  @override
  Future<void> prune({
    required DateTime cutoff,
    required int maxRecords,
  }) async {
    pruneCalls.add((cutoff: cutoff, maxRecords: maxRecords));
    await super.prune(cutoff: cutoff, maxRecords: maxRecords);
  }
}

class _FailingUpsertStore extends InMemoryTransferHistoryStore {
  bool failUpserts = false;

  @override
  Future<void> upsertAll(Iterable<TransferTask> tasks) async {
    if (failUpserts) throw StateError('disk full');
    await super.upsertAll(tasks);
  }
}
