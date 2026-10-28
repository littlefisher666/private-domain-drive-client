import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/transfer/domain/transfer_task.dart';

void main() {
  group('TransferTask 序列化', () {
    test('完整时间线字段往返序列化', () {
      final queuedAt = DateTime.utc(2026, 10, 1, 8);
      final startedAt = DateTime.utc(2026, 10, 1, 8, 1);
      final lastStartedAt = DateTime.utc(2026, 10, 1, 8, 3);
      final finishedAt = DateTime.utc(2026, 10, 1, 8, 5);
      final task = TransferTask(
        id: 'download-1',
        name: '文件.jpg',
        type: TransferTaskType.download,
        status: TransferTaskStatus.success,
        progress: 1,
        message: '已完成',
        target: '/Users/test/文件.jpg',
        totalBytes: 2048,
        transferredBytes: 2048,
        queuedAt: queuedAt,
        startedAt: startedAt,
        lastStartedAt: lastStartedAt,
        finishedAt: finishedAt,
        activeDurationMs: 4000,
        totalTransferredBytes: 2048,
        attemptCount: 3,
      );

      final restored = TransferTask.fromJson(task.toJson());

      expect(restored, isNotNull);
      expect(restored!.queuedAt!.millisecondsSinceEpoch,
          queuedAt.millisecondsSinceEpoch);
      expect(restored.startedAt!.millisecondsSinceEpoch,
          startedAt.millisecondsSinceEpoch);
      expect(restored.lastStartedAt!.millisecondsSinceEpoch,
          lastStartedAt.millisecondsSinceEpoch);
      expect(restored.finishedAt!.millisecondsSinceEpoch,
          finishedAt.millisecondsSinceEpoch);
      expect(restored.activeDurationMs, 4000);
      expect(restored.totalTransferredBytes, 2048);
      expect(restored.attemptCount, 3);
    });

    test('时间字段以 UTC epoch 毫秒写入 JSON', () {
      final local = DateTime(2026, 10, 28, 9, 30);
      final task = TransferTask(
        id: 'upload-1',
        name: 'a.txt',
        type: TransferTaskType.upload,
        status: TransferTaskStatus.success,
        progress: 1,
        finishedAt: local,
      );

      expect(task.toJson()['finishedAt'],
          local.toUtc().millisecondsSinceEpoch);
    });

    test('缺失新增字段时使用默认值，queuedAt 回退到 id 时间戳', () {
      final id = 'download-${DateTime.utc(2026, 9, 1).microsecondsSinceEpoch}-0';
      final restored = TransferTask.fromJson(<String, Object?>{
        'id': id,
        'name': '旧任务.jpg',
        'type': 'download',
        'status': 'success',
        'progress': 1,
      });

      expect(restored, isNotNull);
      expect(restored!.activeDurationMs, 0);
      expect(restored.totalTransferredBytes, 0);
      expect(restored.attemptCount, 1);
      expect(restored.startedAt, isNull);
      expect(restored.finishedAt, isNull);
      expect(restored.queuedTime, isNotNull);
      expect(restored.queuedTime!.year, 2026);
      expect(restored.averageBytesPerSecond, isNull);
    });

    test('基础字段非法时返回 null', () {
      expect(
        TransferTask.fromJson(<String, Object?>{'id': 'x'}),
        isNull,
      );
      expect(
        TransferTask.fromJson(<String, Object?>{
          'id': 'x',
          'name': 'n',
          'type': 'unknown',
          'status': 'success',
          'progress': 1,
        }),
        isNull,
      );
    });
  });

  group('queuedAtFromId', () {
    test('解析合法 id 内嵌的微秒时间戳', () {
      final micros = DateTime.utc(2026, 10, 1, 8, 5).microsecondsSinceEpoch;
      final parsed = TransferTask.queuedAtFromId('download-$micros-12');

      expect(parsed, isNotNull);
      expect(parsed!.millisecondsSinceEpoch,
          DateTime.utc(2026, 10, 1, 8, 5).millisecondsSinceEpoch);
    });

    test('非法或越界 id 返回 null', () {
      expect(TransferTask.queuedAtFromId('download-1'), isNull);
      expect(TransferTask.queuedAtFromId('download-abcdefghijklmnop-0'), isNull);
      expect(TransferTask.queuedAtFromId('download-0000000000000000-0'), isNull);
      final tooLate = DateTime.utc(2101).microsecondsSinceEpoch;
      expect(TransferTask.queuedAtFromId('download-$tooLate-0'), isNull);
    });
  });

  group('TransferTask 派生字段', () {
    const base = TransferTask(
      id: 'upload-1',
      name: 'a.txt',
      type: TransferTaskType.upload,
      status: TransferTaskStatus.running,
      progress: 0.5,
    );

    test('isFinished 按终态判定', () {
      expect(base.isFinished, isFalse);
      for (final status in <TransferTaskStatus>[
        TransferTaskStatus.success,
        TransferTaskStatus.failed,
        TransferTaskStatus.canceled,
      ]) {
        expect(base.copyWith(status: status).isFinished, isTrue);
      }
      expect(
        base.copyWith(status: TransferTaskStatus.interrupted).isFinished,
        isFalse,
      );
    });

    test('平均速度为零时长或未知字节时为空', () {
      expect(base.averageBytesPerSecond, isNull);
      expect(
        base
            .copyWith(activeDurationMs: 1000, totalTransferredBytes: 1024)
            .averageBytesPerSecond,
        1024,
      );
      expect(
        base
            .copyWith(activeDurationMs: 0, totalTransferredBytes: 1024)
            .averageBytesPerSecond,
        isNull,
      );
      expect(
        base
            .copyWith(activeDurationMs: 1000, totalTransferredBytes: 0)
            .averageBytesPerSecond,
        isNull,
      );
    });

    test('copyWith 可清空结束时间', () {
      final failed = base.copyWith(
        status: TransferTaskStatus.failed,
        finishedAt: DateTime.utc(2026, 10, 1),
      );
      expect(failed.copyWith(clearFinishedAt: true).finishedAt, isNull);
      expect(failed.copyWith(status: TransferTaskStatus.pending).finishedAt,
          isNotNull);
    });
  });
}
