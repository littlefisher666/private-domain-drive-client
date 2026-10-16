import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:private_domain_drive_client/features/auth/application/session_controller.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/share_import/application/share_import_controller.dart';
import 'package:private_domain_drive_client/features/share_import/domain/share_import_models.dart';
import 'package:private_domain_drive_client/features/transfer/application/transfer_controller.dart';
import 'package:private_domain_drive_client/features/transfer/application/transfer_queue.dart';
import 'package:private_domain_drive_client/features/transfer/domain/transfer_task.dart';
import 'package:private_domain_drive_client/features/workspace/application/workspace_controller.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/shared/transfer_keepalive.dart';

const _itemA = ShareImportItem(
  id: 'uuid_a.jpg',
  name: '照片A.jpg',
  size: 1024,
  localPath: '/cache/shared-import/uuid_a.jpg',
);
const _itemB = ShareImportItem(
  id: 'uuid_b.jpg',
  name: '照片B.jpg',
  size: 2048,
  localPath: '/cache/shared-import/uuid_b.jpg',
);

void main() {
  group('ShareImportController', () {
    test('批次开始 → 逐项到达 → 批次完成后并入待上传清单', () async {
      final share = await _shareStack();
      addTearDown(share.dispose);

      share.controller.beginShareImportBatch('batch-1', 2);
      expect(share.controller.activeShareBatch, isNotNull);
      expect(share.controller.activeShareBatch!.finished, isFalse);
      expect(share.controller.pendingShareItems, isEmpty);
      expect(share.controller.pendingShareBatchIds, ['batch-1']);

      share.controller.addShareImportItem('batch-1', _itemA);
      expect(share.controller.activeShareBatch!.received, 1);

      share.controller.addShareImportItem('batch-1', _itemB);
      expect(share.controller.activeShareBatch!.received, 2);

      share.controller.finishShareImportBatch(
        'batch-1',
        succeeded: 2,
        failed: 0,
      );

      expect(share.controller.activeShareBatch!.finished, isTrue);
      expect(share.controller.activeShareBatch!.failedCount, 0);
      expect(share.controller.pendingShareItems, hasLength(2));
      expect(share.controller.pendingShareItems.map((item) => item.id),
          ['uuid_a.jpg', 'uuid_b.jpg']);
    });

    test('批次内全部失败时不进入待上传清单', () async {
      final share = await _shareStack();
      addTearDown(share.dispose);

      share.controller.beginShareImportBatch('batch-1', 3);
      share.controller.finishShareImportBatch(
        'batch-1',
        succeeded: 0,
        failed: 3,
      );

      expect(share.controller.activeShareBatch!.finished, isTrue);
      expect(share.controller.activeShareBatch!.failedCount, 3);
      expect(share.controller.pendingShareItems, isEmpty);
    });

    test('不属于当前批次的事件被忽略', () async {
      final share = await _shareStack();
      addTearDown(share.dispose);

      share.controller.beginShareImportBatch('batch-1', 1);
      share.controller.addShareImportItem('batch-other', _itemA);
      share.controller.finishShareImportBatch('batch-other',
          succeeded: 1, failed: 0);

      expect(share.controller.activeShareBatch!.batchId, 'batch-1');
      expect(share.controller.activeShareBatch!.finished, isFalse);
      expect(share.controller.activeShareBatch!.received, 0);
      expect(share.controller.pendingShareItems, isEmpty);
    });

    test('取消弹窗（重置状态）后进行中批次的后续事件被忽略，新批次可正常接收', () async {
      final share = await _shareStack();
      addTearDown(share.dispose);

      share.controller.beginShareImportBatch('batch-1', 2);
      share.controller.addShareImportItem('batch-1', _itemA);
      // 用户取消目录选择弹窗。
      share.controller.prepareShareImport(items: const <ShareImportItem>[]);
      expect(share.controller.pendingShareBatchIds, isEmpty);
      expect(share.controller.activeShareBatch, isNull);

      // 旧批次残余事件不进入待上传清单。
      share.controller.addShareImportItem('batch-1', _itemB);
      share.controller.finishShareImportBatch('batch-1',
          succeeded: 2, failed: 0);
      expect(share.controller.pendingShareItems, isEmpty);

      // 重新分享（新批次）可再次接收并记录批次签名。
      share.controller.beginShareImportBatch('batch-2', 1);
      share.controller.addShareImportItem('batch-2', _itemA);
      share.controller.finishShareImportBatch('batch-2',
          succeeded: 1, failed: 0);
      expect(share.controller.pendingShareItems, hasLength(1));
      expect(share.controller.pendingShareBatchIds, ['batch-2']);
    });

    test('冷启动完整批次直接并入待上传清单', () async {
      final share = await _shareStack();
      addTearDown(share.dispose);

      share.controller.addCompletedShareBatch(const ShareImportCompleteBatch(
        batchId: 'batch-cold',
        items: [_itemA, _itemB],
        succeeded: 2,
        failed: 1,
      ));

      expect(share.controller.pendingShareItems, hasLength(2));
      expect(share.controller.pendingShareBatchIds, ['batch-cold']);

      // 同一批次重复到达不重复记录签名。
      share.controller.addCompletedShareBatch(const ShareImportCompleteBatch(
        batchId: 'batch-cold',
        items: [_itemA],
        succeeded: 1,
        failed: 0,
      ));
      expect(share.controller.pendingShareBatchIds, ['batch-cold']);
      expect(share.controller.pendingShareItems, hasLength(3));
    });

    test('同批次不重复记录防重入签名', () async {
      final share = await _shareStack();
      addTearDown(share.dispose);

      share.controller.beginShareImportBatch('batch-1', 1);
      share.controller.beginShareImportBatch('batch-1', 1);
      expect(share.controller.pendingShareBatchIds, ['batch-1']);
    });

    test('多文件归属同一上传批次', () async {
      final share = await _shareStack();
      addTearDown(share.dispose);
      final directory = await Directory.systemTemp.createTemp('pdd-share-');
      addTearDown(() => directory.delete(recursive: true));
      final fileA = File('${directory.path}/a.jpg');
      final fileB = File('${directory.path}/b.jpg');
      await fileA.writeAsBytes(<int>[1]);
      await fileB.writeAsBytes(<int>[2]);

      share.controller.prepareShareImport(items: <ShareImportItem>[
        ShareImportItem(id: '1', name: 'a.jpg', size: 1, localPath: fileA.path),
        ShareImportItem(id: '2', name: 'b.jpg', size: 1, localPath: fileB.path),
      ]);
      await share.controller.confirmShareUpload();
      await _waitForTaskStatus(
        share.queue,
        TransferTaskStatus.success,
        taskCount: 2,
      );

      final batchIds = share.queue.tasks.map((task) => task.batchId).toSet();
      expect(share.queue.tasks, hasLength(2));
      expect(batchIds, hasLength(1));
      expect(batchIds.single, isNotNull);
    });
  });
}

typedef _ShareStack = ({
  ShareImportController controller,
  TransferQueue queue,
  _FakeOssClient oss,
  void Function() dispose,
});

/// 直测夹层：按生产装配顺序构建 Session → Workspace → Queue →
/// TransferController → ShareImportController，不经过 AppServices 门面。
Future<_ShareStack> _shareStack({_FakeOssClient? oss}) async {
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
    transferKeepalive: const NoopTransferKeepaliveService(),
  );
  await queue.restore(await SharedPreferences.getInstance());
  final transferController = TransferController(
    sessionController: sessionController,
    workspaceController: workspaceController,
    transferQueue: queue,
    ossClient: client,
  );
  final controller = ShareImportController(
    sessionController: sessionController,
    workspaceController: workspaceController,
    transferController: transferController,
  );

  void dispose() {
    queue.markRunningCanceled();
    for (final taskId in queue.runningTaskIds) {
      unawaited(client.cancelTransfer(taskId));
    }
    controller.dispose();
    transferController.dispose();
    queue.dispose();
    workspaceController.dispose();
    sessionController.dispose();
  }

  return (controller: controller, queue: queue, oss: client, dispose: dispose);
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
  final List<({String path, String localPath})> uploads =
      <({String path, String localPath})>[];
  final List<String> canceledTaskIds = <String>[];

  @override
  Future<bool> objectExists(String path, UserSession session) async => false;

  @override
  Future<void> uploadFile(
    String path,
    String localPath,
    UserSession session, {
    required String taskId,
    void Function(int transferredBytes, int totalBytes)? onProgress,
  }) async {
    uploads.add((path: path, localPath: localPath));
    onProgress?.call(1, 1);
  }

  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<void> clearConfiguration() async {}

  @override
  Future<void> cancelTransfer(String taskId) async {
    canceledTaskIds.add(taskId);
  }
}
