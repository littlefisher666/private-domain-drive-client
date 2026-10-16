import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:private_domain_drive_client/features/auth/application/session_controller.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/transfer/application/transfer_controller.dart';
import 'package:private_domain_drive_client/features/transfer/application/transfer_queue.dart';
import 'package:private_domain_drive_client/features/transfer/domain/transfer_task.dart';
import 'package:private_domain_drive_client/features/workspace/application/workspace_controller.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/shared/transfer_keepalive.dart';

void main() {
  group('传输保活', () {
    test('首个任务启动推送 active:true，进度摘要与队列统计一致', () async {
      final gate = Completer<void>();
      final oss = _FakeOssClient()
        ..downloadGate = gate
        // 首报落在 100ms UI 节流窗口内会被跳过，第二次上报才到达任务状态。
        ..progressReports = const <(int, int)>[(50, 200), (50, 200)]
        ..progressInterval = const Duration(milliseconds: 150);
      final keepalive = _RecordingKeepalive();
      final transfer = await _transferStack(oss: oss, keepalive: keepalive);
      addTearDown(transfer.dispose);
      final directory = await Directory.systemTemp.createTemp('pdd-keepalive-');
      addTearDown(() => directory.delete(recursive: true));

      transfer.controller.enqueueDownload(
        const FileItem(
          path: 'shared/a.txt',
          name: 'a.txt',
          isDirectory: false,
          size: 200,
        ),
        targetDirectory: directory.path,
      );
      await _waitForKeepaliveCall(keepalive, (call) => call.active);
      expect(keepalive.calls.first.active, isTrue);
      expect(keepalive.calls.first.summary,
          const TransferProgressSummary(
              remainingCount: 1, completedCount: 0, totalCount: 1, percent: 0));

      gate.complete();
      await _waitForTaskStatus(transfer.queue, TransferTaskStatus.success);
      await _waitForKeepaliveCall(keepalive, (call) => !call.active);
      expect(keepalive.calls.last.active, isFalse);
      expect(keepalive.calls.last.summary, isNull);
      // 进度上报会触发保活同步：等待字节进度落地到任务状态。
      final progressDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (transfer.queue.tasks.single.progress < 0.25) {
        if (DateTime.now().isAfter(progressDeadline)) {
          fail('进度上报未落地：${transfer.queue.tasks.single.progress}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // 进度摘要与队列统计一致：百分比按文件数计，字节进度变化不改变摘要。
      expect(
        keepalive.calls
            .where((call) => call.active)
            .every((call) =>
                call.summary ==
                const TransferProgressSummary(
                    remainingCount: 1,
                    completedCount: 0,
                    totalCount: 1,
                    percent: 0)),
        isTrue,
      );
    });

    test('取消全部任务后推送 active:false', () async {
      final gate = Completer<void>();
      final oss = _FakeOssClient()..downloadGate = gate;
      final keepalive = _RecordingKeepalive();
      final transfer = await _transferStack(oss: oss, keepalive: keepalive);
      addTearDown(transfer.dispose);
      final directory = await Directory.systemTemp.createTemp('pdd-keepalive-');
      addTearDown(() => directory.delete(recursive: true));

      transfer.controller.enqueueDownload(
        const FileItem(
          path: 'shared/a.txt',
          name: 'a.txt',
          isDirectory: false,
          size: 200,
        ),
        targetDirectory: directory.path,
      );
      await _waitForKeepaliveCall(keepalive, (call) => call.active);
      expect(keepalive.calls.first.active, isTrue);

      transfer.controller.cancelTask(transfer.queue.tasks.single.id);
      gate.complete();
      await _waitForKeepaliveCall(keepalive, (call) => !call.active);
      expect(keepalive.calls.last.active, isFalse);
      expect(keepalive.calls.last.summary, isNull);
    });

    test('通知权限请求只在首个任务发起时调用一次', () async {
      final keepalive = _RecordingKeepalive();
      final transfer = await _transferStack(keepalive: keepalive);
      addTearDown(transfer.dispose);
      final directory = await Directory.systemTemp.createTemp('pdd-keepalive-');
      addTearDown(() => directory.delete(recursive: true));

      await transfer.controller.uploadFile(
        fileName: 'a.txt',
        localPath: '/fake/a.txt',
        fileSize: 1,
      );
      transfer.controller.enqueueDownload(
        const FileItem(
            path: 'shared/b.txt', name: 'b.txt', isDirectory: false),
        targetDirectory: directory.path,
      );
      transfer.controller.enqueueDownload(
        const FileItem(
            path: 'shared/c.txt', name: 'c.txt', isDirectory: false),
        targetDirectory: directory.path,
      );
      await _waitForTaskStatus(
        transfer.queue,
        TransferTaskStatus.success,
        taskCount: 3,
      );

      expect(keepalive.permissionRequests, 1);
    });
  });

  group('TransferController', () {
    test('启动后会恢复本地传输历史', () async {
      const completedTask = TransferTask(
        id: 'download-history-1',
        name: '已下载文件.jpg',
        type: TransferTaskType.download,
        status: TransferTaskStatus.success,
        progress: 1,
        target: '/Users/test/Downloads/已下载文件.jpg',
        totalBytes: 1024,
      );
      const failedTask = TransferTask(
        id: 'upload-failed-1',
        name: '未完成文件.jpg',
        type: TransferTaskType.upload,
        status: TransferTaskStatus.failed,
        progress: 0.5,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        'transfer_history:v1': jsonEncode(<Map<String, Object?>>[
          completedTask.toJson(),
          failedTask.toJson(),
        ]),
      });
      final queue = TransferQueue(
        transferKeepalive: const NoopTransferKeepaliveService(),
      );

      await queue.restore(await SharedPreferences.getInstance());

      expect(queue.tasks, hasLength(1));
      expect(queue.tasks.single.id, completedTask.id);
      expect(queue.tasks.single.status, TransferTaskStatus.success);
      expect(queue.tasks.single.target, completedTask.target);
      queue.dispose();
      await (await SharedPreferences.getInstance())
          .remove('transfer_history:v1');
    });

    test('上传与下载使用正确路径，并阻止文件夹下载', () async {
      final oss = _FakeOssClient()..downloadResult = <int>[1, 2, 3];
      final transfer = await _transferStack(oss: oss);
      addTearDown(transfer.dispose);

      final source = File('${Directory.systemTemp.path}/pdd-upload-source.txt');
      await source.writeAsBytes(<int>[7]);
      await transfer.controller.uploadFile(
        fileName: '中文 文件.txt',
        localPath: source.path,
        fileSize: 1,
      );
      final bytes = await transfer.controller.downloadBytes(
        const FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
      );
      await expectLater(
        transfer.controller.downloadBytes(
          const FileItem(path: 'shared/目录/', name: '目录', isDirectory: true),
        ),
        throwsA(isA<StateError>()),
      );

      expect(oss.uploads.single.path, 'shared/中文 文件.txt');
      expect(transfer.queue.tasks.single.sourcePath, source.path);
      expect(bytes, <int>[1, 2, 3]);
    });

    test('失败任务可重试，进行中任务可取消', () async {
      final transfer = await _transferStack();
      addTearDown(transfer.dispose);
      transfer.queue.tasksListenable.value = const <TransferTask>[
        TransferTask(
          id: 'upload-1',
          name: '文件.txt',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.failed,
          progress: 0,
        ),
      ];

      transfer.controller.retryTask('upload-1');
      expect(transfer.queue.tasks.single.status, TransferTaskStatus.running);
      transfer.controller.cancelTask('upload-1');

      expect(transfer.queue.tasks.single.status, TransferTaskStatus.canceled);
      expect(transfer.queue.tasks.single.message, '已取消');
    });

    test('批次汇总统计独立下载任务', () async {
      final transfer = await _transferStack();
      addTearDown(transfer.dispose);
      transfer.queue.tasksListenable.value = const <TransferTask>[
        TransferTask(
          id: 'a',
          name: 'a.txt',
          type: TransferTaskType.download,
          status: TransferTaskStatus.success,
          progress: 1,
          batchId: 'batch-1',
        ),
        TransferTask(
          id: 'b',
          name: 'b.txt',
          type: TransferTaskType.download,
          status: TransferTaskStatus.pending,
          progress: 0,
          batchId: 'batch-1',
        ),
      ];

      // 批次不再有界面汇总；batchId 仅作为冲突处置整批应用的内部分组。
      expect(
          transfer.queue.tasks.where((task) => task.batchId == 'batch-1'),
          hasLength(2));
    });

    test('上传目标已存在且无对话框上下文时按跳过处理', () async {
      final oss = _FakeOssClient()..existingPaths.add('shared/已存在.txt');
      final transfer = await _transferStack(oss: oss);
      addTearDown(transfer.dispose);

      await transfer.controller.uploadFile(
        fileName: '已存在.txt',
        localPath: '/fake/已存在.txt',
        fileSize: 1,
      );
      await _waitForTaskStatus(transfer.queue, TransferTaskStatus.success);

      final task = transfer.queue.tasks.single;
      expect(task.status, TransferTaskStatus.success);
      expect(task.message, '已存在，跳过');
      expect(oss.uploads, isEmpty);
    });

    testWidgets('上传已存在文件弹出处置对话框并支持整批应用', (tester) async {
      final oss = _FakeOssClient()
        ..existingPaths.addAll(<String>['shared/a.txt', 'shared/b.txt']);
      final transfer = await _transferStack(oss: oss);
      addTearDown(transfer.dispose);
      final navigatorKey = GlobalKey<NavigatorState>();
      transfer.controller.setNavigatorKey(navigatorKey);
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );

      await transfer.controller.uploadFile(
        fileName: 'a.txt',
        localPath: '/fake/a.txt',
        fileSize: 1,
        batchId: 'batch-1',
      );
      await transfer.controller.uploadFile(
        fileName: 'b.txt',
        localPath: '/fake/b.txt',
        fileSize: 1,
        batchId: 'batch-1',
      );
      await tester.pumpAndSettle();

      // 同批多个已存在任务只弹一次对话框。
      expect(find.text('云端已存在同名文件'), findsOneWidget);
      expect(find.text('同批其余 1 个文件应用相同处理'), findsOneWidget);
      await tester.tap(find.text('覆盖'));
      await tester.pump();
      await tester.tap(find.text('同批其余 1 个文件应用相同处理'));
      await tester.pump();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(
        oss.uploads.map((upload) => upload.path).toSet(),
        <String>{'shared/a.txt', 'shared/b.txt'},
      );
      expect(
        transfer.queue.tasks
            .every((task) => task.status == TransferTaskStatus.success),
        isTrue,
      );
    });

    testWidgets('保留两者时探测序号新键上传', (tester) async {
      final oss = _FakeOssClient()..existingPaths.add('shared/a.txt');
      final transfer = await _transferStack(oss: oss);
      addTearDown(transfer.dispose);
      final navigatorKey = GlobalKey<NavigatorState>();
      transfer.controller.setNavigatorKey(navigatorKey);
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );

      await transfer.controller.uploadFile(
        fileName: 'a.txt',
        localPath: '/fake/a.txt',
        fileSize: 1,
      );
      await tester.pumpAndSettle();

      expect(find.text('云端已存在同名文件'), findsOneWidget);
      // 默认选中跳过，切到保留两者后直接确认。
      await tester.tap(find.text('保留两者'));
      await tester.pump();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(oss.uploads.single.path, 'shared/a（1）.txt');
      expect(transfer.queue.tasks.single.status, TransferTaskStatus.success);
    });

    testWidgets('跳过时任务标记完成且不发起上传', (tester) async {
      final oss = _FakeOssClient()..existingPaths.add('shared/a.txt');
      final transfer = await _transferStack(oss: oss);
      addTearDown(transfer.dispose);
      final navigatorKey = GlobalKey<NavigatorState>();
      transfer.controller.setNavigatorKey(navigatorKey);
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );

      await transfer.controller.uploadFile(
        fileName: 'a.txt',
        localPath: '/fake/a.txt',
        fileSize: 1,
      );
      await tester.pumpAndSettle();

      // 单文件任务不提供整批应用选项。
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.tap(find.text('跳过'));
      await tester.pump();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(oss.uploads, isEmpty);
      final task = transfer.queue.tasks.single;
      expect(task.status, TransferTaskStatus.success);
      expect(task.message, '已存在，跳过');
    });

    test('下载队列遵守动态并发上限', () async {
      final gate = Completer<void>();
      final oss = _FakeOssClient()..downloadGate = gate;
      final transfer = await _transferStack(oss: oss);
      addTearDown(transfer.dispose);
      await transfer.queue.setTransferConcurrency(1);
      final directory = await Directory.systemTemp.createTemp('pdd-transfer-');
      addTearDown(() => directory.delete(recursive: true));
      const files = <FileItem>[
        FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
        FileItem(path: 'shared/b.txt', name: 'b.txt', isDirectory: false),
      ];

      transfer.controller.enqueueDownloads(files, targetDirectory: directory.path);
      await Future<void>.delayed(Duration.zero);
      expect(transfer.queue.runningTransferCount, 1);
      expect(transfer.queue.pendingTransferCount, 1);

      await transfer.queue.setTransferConcurrency(2);
      await Future<void>.delayed(Duration.zero);
      expect(transfer.queue.runningTransferCount, 2);
      expect(transfer.queue.pendingTransferCount, 0);

      gate.complete();
      await _waitForTaskStatus(
        transfer.queue,
        TransferTaskStatus.success,
        taskCount: 2,
      );
      expect(
          transfer.queue.tasks
              .where((task) => task.status == TransferTaskStatus.success),
          hasLength(2));
    });

    test('递归下载保留目录结构并去重重叠选择', () async {
      final oss = _FakeOssClient()
        ..objectKeysByPath['shared/资料/'] = <String>[
          'shared/资料/',
          'shared/资料/a.txt',
          'shared/资料/子目录/b.txt',
        ];
      final transfer = await _transferStack(oss: oss);
      addTearDown(transfer.dispose);
      final directory = await Directory.systemTemp.createTemp('pdd-recursive-');
      addTearDown(() => directory.delete(recursive: true));

      final result = await transfer.controller.enqueueDownloadsRecursively(
        const <FileItem>[
          FileItem(path: 'shared/资料/', name: '资料', isDirectory: true),
          FileItem(path: 'shared/资料/a.txt', name: 'a.txt', isDirectory: false),
        ],
        targetDirectory: directory.path,
      );
      expect(result.fileCount, 2);
      expect(result.directoryCount, 1);
      await _waitForTaskStatus(
        transfer.queue,
        TransferTaskStatus.success,
        taskCount: 2,
      );

      expect(
          transfer.queue.tasks.where((task) => task.batchId == result.batchId),
          hasLength(2));
      expect(await File('${directory.path}/资料/a.txt').exists(), isTrue);
      expect(await File('${directory.path}/资料/子目录/b.txt').exists(), isTrue);
    });
    test('同名下载目标自动递增改名并保留扩展名', () async {
      final transfer = await _transferStack();
      addTearDown(transfer.dispose);
      final directory = await Directory.systemTemp.createTemp('pdd-rename-');
      addTearDown(() => directory.delete(recursive: true));
      // 占用原名与第一次递增名，应继续递增到 (2)。
      await File('${directory.path}/a.txt').writeAsBytes(<int>[0]);
      await File('${directory.path}/a (1).txt').writeAsBytes(<int>[0]);

      transfer.controller.enqueueDownload(
        const FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
        targetDirectory: directory.path,
      );
      await _waitForTaskStatus(transfer.queue, TransferTaskStatus.success);

      final task = transfer.queue.tasks.single;
      expect(task.status, TransferTaskStatus.success);
      expect(task.target, '${directory.path}/a (2).txt');
      expect(await File('${directory.path}/a (2).txt').exists(), isTrue);
      // 原有文件不被覆盖。
      expect(await File('${directory.path}/a.txt').readAsBytes(), <int>[0]);
    });

    test('无扩展名同名下载目标自动改名', () async {
      final transfer = await _transferStack();
      addTearDown(transfer.dispose);
      final directory =
          await Directory.systemTemp.createTemp('pdd-rename-noext-');
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/README').writeAsBytes(<int>[0]);

      transfer.controller.enqueueDownload(
        const FileItem(
            path: 'shared/README', name: 'README', isDirectory: false),
        targetDirectory: directory.path,
      );
      await _waitForTaskStatus(transfer.queue, TransferTaskStatus.success);

      expect(transfer.queue.tasks.single.status, TransferTaskStatus.success);
      expect(transfer.queue.tasks.single.target, '${directory.path}/README (1)');
    });

    test('下载失败时清理 part 临时文件并标记失败', () async {
      final oss = _FakeOssClient()
        ..downloadToFileError = const SocketException('网络中断');
      final transfer = await _transferStack(oss: oss);
      addTearDown(transfer.dispose);
      final directory = await Directory.systemTemp.createTemp('pdd-part-fail-');
      addTearDown(() => directory.delete(recursive: true));

      transfer.controller.enqueueDownload(
        const FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
        targetDirectory: directory.path,
      );
      await _waitForTaskStatus(
        transfer.queue,
        TransferTaskStatus.failed,
      );

      final task = transfer.queue.tasks.single;
      expect(task.status, TransferTaskStatus.failed);
      expect(await directory.list().toList(), isEmpty);
    });

    test('下载取消时清理 part 临时文件', () async {
      final gate = Completer<void>();
      final oss = _FakeOssClient()..downloadGate = gate;
      final transfer = await _transferStack(oss: oss);
      addTearDown(transfer.dispose);
      final directory =
          await Directory.systemTemp.createTemp('pdd-part-cancel-');
      addTearDown(() => directory.delete(recursive: true));

      transfer.controller.enqueueDownload(
        const FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
        targetDirectory: directory.path,
      );
      // 等待任务开始运行并已在临时文件上写入数据。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      transfer.controller.cancelTask(transfer.queue.tasks.single.id);
      gate.complete();
      await _waitForTaskStatus(transfer.queue, TransferTaskStatus.canceled);

      final task = transfer.queue.tasks.single;
      expect(task.status, TransferTaskStatus.canceled);
      expect(oss.canceledTaskIds, contains(task.id));
      // cancelTask 同步标记取消状态，part 清理发生在下载流程退出之后，
      // 仅等待状态到达取消会与清理产生竞态，需单独等待目录清空。
      await _waitForDirectoryEmpty(directory);
      expect(await directory.list().toList(), isEmpty);
    });

    test('字节完成后等待 OSS 确认并使用时间窗口计算速度', () async {
      final gate = Completer<void>();
      final oss = _FakeOssClient()
        ..downloadGate = gate
        ..progressReports = <(int, int)>[(25, 100), (100, 100)]
        ..progressInterval = const Duration(milliseconds: 600);
      final transfer = await _transferStack(oss: oss);
      addTearDown(transfer.dispose);
      final directory = await Directory.systemTemp.createTemp('pdd-confirm-');
      addTearDown(() => directory.delete(recursive: true));

      transfer.controller.enqueueDownload(
        const FileItem(path: 'shared/a.bin', name: 'a.bin', isDirectory: false),
        targetDirectory: directory.path,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1300));

      final confirming = transfer.queue.tasks.single;
      expect(confirming.status, TransferTaskStatus.running);
      expect(confirming.message, '正在确认');
      expect(confirming.progress, 1);
      expect(confirming.bytesPerSecond, greaterThan(0));

      gate.complete();
      await _waitForTaskStatus(transfer.queue, TransferTaskStatus.success);
      expect(transfer.queue.tasks.single.status, TransferTaskStatus.success);
    });
  });
}

typedef _TransferStack = ({
  TransferController controller,
  TransferQueue queue,
  _FakeOssClient oss,
  void Function() dispose,
});

/// 直测夹层：按生产装配顺序构建 Session → Workspace → Queue →
/// TransferController，不经过 AppServices 门面。
Future<_TransferStack> _transferStack({
  _FakeOssClient? oss,
  TransferKeepaliveService? keepalive,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final client = oss ?? _FakeOssClient();
  final sessionController = SessionController(
    sessionRepository: _FakeSessionRepository(_remoteSession()),
    ossClient: client,
  );
  await sessionController.bootstrap();
  final workspaceController = WorkspaceController(
    sessionController: sessionController,
    ossClient: client,
  );
  final queue = TransferQueue(
    transferKeepalive: keepalive ?? const NoopTransferKeepaliveService(),
  );
  await queue.restore(await SharedPreferences.getInstance());
  final controller = TransferController(
    sessionController: sessionController,
    workspaceController: workspaceController,
    transferQueue: queue,
    ossClient: client,
  );

  void dispose() {
    queue.markRunningCanceled();
    for (final taskId in queue.runningTaskIds) {
      unawaited(client.cancelTransfer(taskId));
    }
    controller.dispose();
    queue.dispose();
    workspaceController.dispose();
    sessionController.dispose();
  }

  return (
    controller: controller,
    queue: queue,
    oss: client,
    dispose: dispose,
  );
}

class _RecordingKeepalive extends TransferKeepaliveService {
  final List<({bool active, TransferProgressSummary? summary})> calls =
      <({bool active, TransferProgressSummary? summary})>[];
  int permissionRequests = 0;

  @override
  Future<void> sync(
      {required bool active, TransferProgressSummary? summary}) async {
    calls.add((active: active, summary: summary));
  }

  @override
  Future<void> requestNotificationPermissionIfNeeded() async {
    permissionRequests++;
  }
}

Future<void> _waitForKeepaliveCall(
  _RecordingKeepalive keepalive,
  bool Function(({bool active, TransferProgressSummary? summary})) predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!keepalive.calls.any(predicate)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('keepalive 未收到预期调用：${keepalive.calls}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitForTaskStatus(
  TransferQueue queue,
  TransferTaskStatus status, {
  int taskCount = 1,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  bool reached() {
    if (queue.tasks.length != taskCount) return false;
    return queue.tasks.every((task) => task.status == status);
  }

  while (!reached()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('传输任务未在限定时间内全部进入 $status 状态');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitForDirectoryEmpty(Directory directory) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while ((await directory.list().toList()).isNotEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('目录未在限定时间内清空：${directory.path}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

UserSession _remoteSession() {
  return const UserSession(
    userId: 'test-user',
    account: 'test',
    displayName: '测试成员',
    role: 'member',
    capabilities: Capabilities.standard(),
    rootPrefix: 'shared/',
    ossConfig: OssConfig(
      bucket: 'test-bucket',
      region: 'cn-hangzhou',
      endpoint: 'oss-cn-hangzhou.aliyuncs.com',
      rootPrefix: 'shared/',
    ),
    credentials: OssCredentials(
      accessKeyId: 'id',
      accessKeySecret: 'secret',
    ),
  );
}

class _FakeSessionRepository implements SessionRepository {
  _FakeSessionRepository(this.session);

  final UserSession session;

  @override
  Future<void> logout() async {}

  @override
  Future<UserSession> login(
          {required String account, required String password}) async =>
      session;

  @override
  Future<UserSession> changePassword({
    required UserSession session,
    required String currentPassword,
    required String newPassword,
  }) async =>
      session.copyWith(mustResetPassword: false);

  @override
  Future<UserSession?> restore() async => session;
}

class _FakeOssClient extends OssClient {
  final Map<String, List<FileItem>> itemsByPath = <String, List<FileItem>>{};
  final Map<String, List<String>> objectKeysByPath = <String, List<String>>{};
  final Map<String, int> directorySizes = <String, int>{};
  final Set<String> existingPaths = <String>{};
  int directorySizeCalls = 0;
  final List<String> createdFolders = <String>[];
  final List<String> deleted = <String>[];
  final List<(String, String)> copies = <(String, String)>[];
  final List<({String path, String localPath})> uploads =
      <({String path, String localPath})>[];
  List<int> downloadResult = const <int>[];
  Completer<void>? downloadGate;
  Object? downloadToFileError;
  List<(int, int)> progressReports = <(int, int)>[];
  Duration progressInterval = Duration.zero;
  final List<String> canceledTaskIds = <String>[];

  @override
  Future<List<FileItem>> list(String path, UserSession session) async =>
      itemsByPath[path] ?? const <FileItem>[];

  @override
  Future<List<String>> listAllObjectKeys(
          String path, UserSession session) async =>
      objectKeysByPath[path] ?? const <String>[];

  @override
  Future<int> calculateDirectorySize(String path, UserSession session) async {
    directorySizeCalls++;
    return directorySizes[path] ?? 0;
  }

  @override
  Future<void> createFolder(String path, UserSession session) async {
    createdFolders.add(path);
  }

  @override
  Future<void> copy(String from, String to, UserSession session) async {
    copies.add((from, to));
  }

  @override
  Future<bool> objectExists(String path, UserSession session) async =>
      existingPaths.contains(path);

  @override
  Future<void> delete(String path, UserSession session) async {
    deleted.add(path);
  }

  @override
  Future<BatchDeleteResult> deleteMany(
    Iterable<String> paths,
    UserSession session,
  ) async {
    final values = paths.toList(growable: false);
    deleted.addAll(values);
    return BatchDeleteResult(deletedPaths: values);
  }

  @override
  Future<void> uploadFile(
    String path,
    String localPath,
    UserSession session, {
    required String taskId,
    void Function(int transferredBytes, int totalBytes)? onProgress,
  }) async {
    uploads.add((path: path, localPath: localPath));
    // 不读取真实文件，保证 testWidgets 的 FakeAsync 环境下可完成。
    onProgress?.call(1, 1);
  }

  @override
  Future<List<int>> download(
    String path,
    UserSession session, {
    int? maxBytes,
  }) async =>
      downloadResult;

  @override
  Future<List<String>> listPrefixes(
    String prefix,
    UserSession session,
  ) async =>
      const <String>[];

  @override
  Future<void> downloadToFile(
    String path,
    UserSession session,
    File target, {
    required String taskId,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {
    // 先落盘再等待闸门，模拟流式写入中途被取消/失败的场景。
    await target.parent.create(recursive: true);
    await target.writeAsBytes(<int>[1], flush: true);
    for (final report in progressReports) {
      onProgress(report.$1, report.$2);
      if (progressInterval > Duration.zero) {
        await Future<void>.delayed(progressInterval);
      }
    }
    final gate = downloadGate;
    if (gate != null) await gate.future;
    if (isCanceled()) throw const TransferCanceledException();
    onProgress(1, 1);
    final error = downloadToFileError;
    if (error != null) throw error;
  }

  @override
  Future<void> downloadToMediaStore(
    String path,
    UserSession session, {
    required String displayName,
    required String collection,
    required String taskId,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {}

  @override
  Future<void> downloadToDirectoryUri(
    String path,
    UserSession session, {
    required String directoryUri,
    required String displayName,
    required String taskId,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {}

  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<void> clearConfiguration() async {}

  @override
  Future<void> cancelTransfer(String taskId) async {
    canceledTaskIds.add(taskId);
  }
}
