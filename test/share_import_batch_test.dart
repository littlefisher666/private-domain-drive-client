import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/saved_credentials_store.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';

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

AppController _createController() => AppController(
      sessionRepository: MemorySessionRepository(),
      savedCredentialsStore:
          SavedCredentialsStore(storage: InMemoryCredentialsStorage()),
    );

void main() {
  group('AppController 分享批次渐进接收', () {
    test('批次开始 → 逐项到达 → 批次完成后并入待上传清单', () {
      final controller = _createController();
      addTearDown(controller.dispose);

      controller.beginShareImportBatch('batch-1', 2);
      expect(controller.activeShareBatch, isNotNull);
      expect(controller.activeShareBatch!.finished, isFalse);
      expect(controller.pendingShareItems, isEmpty);
      expect(controller.pendingShareBatchIds, ['batch-1']);

      controller.addShareImportItem('batch-1', _itemA);
      expect(controller.activeShareBatch!.received, 1);

      controller.addShareImportItem('batch-1', _itemB);
      expect(controller.activeShareBatch!.received, 2);

      controller.finishShareImportBatch(
        'batch-1',
        succeeded: 2,
        failed: 0,
      );

      expect(controller.activeShareBatch!.finished, isTrue);
      expect(controller.activeShareBatch!.failedCount, 0);
      expect(controller.pendingShareItems, hasLength(2));
      expect(controller.pendingShareItems.map((item) => item.id),
          ['uuid_a.jpg', 'uuid_b.jpg']);
    });

    test('批次内全部失败时不进入待上传清单', () {
      final controller = _createController();
      addTearDown(controller.dispose);

      controller.beginShareImportBatch('batch-1', 3);
      controller.finishShareImportBatch(
        'batch-1',
        succeeded: 0,
        failed: 3,
      );

      expect(controller.activeShareBatch!.finished, isTrue);
      expect(controller.activeShareBatch!.failedCount, 3);
      expect(controller.pendingShareItems, isEmpty);
    });

    test('不属于当前批次的事件被忽略', () {
      final controller = _createController();
      addTearDown(controller.dispose);

      controller.beginShareImportBatch('batch-1', 1);
      controller.addShareImportItem('batch-other', _itemA);
      controller.finishShareImportBatch('batch-other', succeeded: 1, failed: 0);

      expect(controller.activeShareBatch!.batchId, 'batch-1');
      expect(controller.activeShareBatch!.finished, isFalse);
      expect(controller.activeShareBatch!.received, 0);
      expect(controller.pendingShareItems, isEmpty);
    });

    test('取消弹窗（重置状态）后进行中批次的后续事件被忽略，新批次可正常接收', () {
      final controller = _createController();
      addTearDown(controller.dispose);

      controller.beginShareImportBatch('batch-1', 2);
      controller.addShareImportItem('batch-1', _itemA);
      // 用户取消目录选择弹窗。
      controller.prepareShareImport(items: const <ShareImportItem>[]);
      expect(controller.pendingShareBatchIds, isEmpty);
      expect(controller.activeShareBatch, isNull);

      // 旧批次残余事件不进入待上传清单。
      controller.addShareImportItem('batch-1', _itemB);
      controller.finishShareImportBatch('batch-1', succeeded: 2, failed: 0);
      expect(controller.pendingShareItems, isEmpty);

      // 重新分享（新批次）可再次接收并记录批次签名。
      controller.beginShareImportBatch('batch-2', 1);
      controller.addShareImportItem('batch-2', _itemA);
      controller.finishShareImportBatch('batch-2', succeeded: 1, failed: 0);
      expect(controller.pendingShareItems, hasLength(1));
      expect(controller.pendingShareBatchIds, ['batch-2']);
    });

    test('冷启动完整批次直接并入待上传清单', () {
      final controller = _createController();
      addTearDown(controller.dispose);

      controller.addCompletedShareBatch(const ShareImportCompleteBatch(
        batchId: 'batch-cold',
        items: [_itemA, _itemB],
        succeeded: 2,
        failed: 1,
      ));

      expect(controller.pendingShareItems, hasLength(2));
      expect(controller.pendingShareBatchIds, ['batch-cold']);

      // 同一批次重复到达不重复记录签名。
      controller.addCompletedShareBatch(const ShareImportCompleteBatch(
        batchId: 'batch-cold',
        items: [_itemA],
        succeeded: 1,
        failed: 0,
      ));
      expect(controller.pendingShareBatchIds, ['batch-cold']);
      expect(controller.pendingShareItems, hasLength(3));
    });

    test('同批次不重复记录防重入签名', () {
      final controller = _createController();
      addTearDown(controller.dispose);

      controller.beginShareImportBatch('batch-1', 1);
      controller.beginShareImportBatch('batch-1', 1);
      expect(controller.pendingShareBatchIds, ['batch-1']);
    });
  });
}
