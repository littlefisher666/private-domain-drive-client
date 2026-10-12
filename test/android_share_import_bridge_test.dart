import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/share_import/infrastructure/android_share_import_bridge.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidShareImportBridge 信封事件解析', () {
    test('batch_start 解析为类型化事件', () {
      final event = AndroidShareImportBridge.parseEvent(<Object?, Object?>{
        'type': 'batch_start',
        'batchId': 'batch-1',
        'total': 3,
      });

      expect(event, isA<ShareImportBatchStart>());
      final start = event! as ShareImportBatchStart;
      expect(start.batchId, 'batch-1');
      expect(start.total, 3);
    });

    test('item 事件解析出单个导入项', () {
      final event = AndroidShareImportBridge.parseEvent(<Object?, Object?>{
        'type': 'item',
        'batchId': 'batch-1',
        'item': <Object?, Object?>{
          'id': 'uuid_a.jpg',
          'name': '照片A.jpg',
          'size': 1024,
          'path': '/cache/shared-import/uuid_a.jpg',
        },
      });

      expect(event, isA<ShareImportItemEvent>());
      final item = event! as ShareImportItemEvent;
      expect(item.batchId, 'batch-1');
      expect(item.item.id, 'uuid_a.jpg');
      expect(item.item.name, '照片A.jpg');
      expect(item.item.size, 1024);
      expect(item.item.localPath, '/cache/shared-import/uuid_a.jpg');
    });

    test('batch_done 解析成功与失败计数', () {
      final event = AndroidShareImportBridge.parseEvent(<Object?, Object?>{
        'type': 'batch_done',
        'batchId': 'batch-1',
        'succeeded': 9,
        'failed': 2,
      });

      expect(event, isA<ShareImportBatchDone>());
      final done = event! as ShareImportBatchDone;
      expect(done.succeeded, 9);
      expect(done.failed, 2);
    });

    test('未知事件类型忽略并返回 null', () {
      final event = AndroidShareImportBridge.parseEvent(<Object?, Object?>{
        'type': 'something_new',
        'batchId': 'batch-1',
      });

      expect(event, isNull);
    });

    test('非 Map 与缺少有效路径的 item 返回 null', () {
      expect(AndroidShareImportBridge.parseEvent('not-a-map'), isNull);
      expect(
        AndroidShareImportBridge.parseEvent(<Object?, Object?>{
          'type': 'item',
          'batchId': 'batch-1',
          'item': <Object?, Object?>{'id': 'x', 'path': ''},
        }),
        isNull,
      );
    });

    test('takePendingBatches 返回完整批次列表', () async {
      const channel = MethodChannel('private_domain_drive/share_import');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'takePendingItems');
        return <Object>[
          <Object?, Object?>{
            'type': 'batch',
            'batchId': 'batch-1',
            'items': <Object>[
              <Object?, Object?>{
                'id': 'uuid_a.jpg',
                'name': '照片A.jpg',
                'size': 1024,
                'path': '/cache/shared-import/uuid_a.jpg',
              },
            ],
            'succeeded': 1,
            'failed': 1,
          },
        ];
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final batches = await AndroidShareImportBridge.takePendingBatches();

      expect(batches, hasLength(1));
      expect(batches.single.batchId, 'batch-1');
      expect(batches.single.items.single.name, '照片A.jpg');
      expect(batches.single.succeeded, 1);
      expect(batches.single.failed, 1);
      expect(batches.single.items.single, isA<ShareImportItem>());
    });
  });
}
