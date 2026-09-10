import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/transfer/domain/transfer_task.dart';
import 'package:private_domain_drive_client/features/transfer/presentation/transfer_tasks_page.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';
import 'package:private_domain_drive_client/shared/state/app_scope.dart';

void main() {
  Future<AppController> pumpTasks(
    WidgetTester tester,
    List<TransferTask> tasks,
  ) async {
    final controller =
        AppController(sessionRepository: MemorySessionRepository());
    controller.tasksListenable.value = tasks;
    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: const MaterialApp(
          home: Scaffold(
            body: TransferTasksPage(embedded: true, desktopChrome: true),
          ),
        ),
      ),
    );
    return controller;
  }

  testWidgets('无任务时展示空状态', (tester) async {
    await pumpTasks(tester, const <TransferTask>[]);

    expect(find.text('暂无传输任务'), findsOneWidget);
  });

  testWidgets('可按上传和下载分别查看任务', (tester) async {
    await pumpTasks(
      tester,
      const <TransferTask>[
        TransferTask(
          id: 'upload-1',
          name: '照片.jpg',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.success,
          progress: 1,
        ),
        TransferTask(
          id: 'download-1',
          name: '资料.pdf',
          type: TransferTaskType.download,
          status: TransferTaskStatus.success,
          progress: 1,
        ),
      ],
    );

    expect(find.text('上传 1'), findsOneWidget);
    expect(find.text('下载 1'), findsOneWidget);
    await tester.tap(find.text('上传 1'));
    await tester.pump();

    expect(find.text('上传 · 照片.jpg'), findsOneWidget);
    expect(find.text('下载 · 资料.pdf'), findsNothing);
  });

  testWidgets('失败任务可重试，进行中任务可取消', (tester) async {
    final controller = await pumpTasks(
      tester,
      const <TransferTask>[
        TransferTask(
          id: 'download-1',
          name: '资料.pdf',
          type: TransferTaskType.download,
          status: TransferTaskStatus.failed,
          progress: 0.3,
          message: '网络错误',
        ),
      ],
    );

    expect(find.text('下载 · 资料.pdf'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(controller.tasks.single.status, TransferTaskStatus.running);

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(controller.tasks.single.status, TransferTaskStatus.canceled);
    expect(find.text('已取消'), findsWidgets);
  });

  testWidgets('可全选任务后批量重试和取消', (tester) async {
    final controller = await pumpTasks(
      tester,
      const <TransferTask>[
        TransferTask(
          id: 'failed-1',
          name: '失败文件',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.failed,
          progress: 0,
        ),
        TransferTask(
          id: 'canceled-1',
          name: '已取消文件',
          type: TransferTaskType.download,
          status: TransferTaskStatus.canceled,
          progress: 0.2,
        ),
        TransferTask(
          id: 'pending-1',
          name: '等待文件',
          type: TransferTaskType.download,
          status: TransferTaskStatus.pending,
          progress: 0,
        ),
      ],
    );

    await tester.tap(find.text('全选当前列表'));
    await tester.pump();
    await tester.tap(find.text('批量重试 (2)'));
    await tester.pump();
    expect(
      controller.tasks
          .where((task) => task.id != 'pending-1')
          .every((task) => task.status == TransferTaskStatus.running),
      isTrue,
    );

    await tester.tap(find.text('全选当前列表'));
    await tester.pump();
    await tester.tap(find.text('批量取消 (3)'));
    await tester.pump();
    expect(
      controller.tasks
          .every((task) => task.status == TransferTaskStatus.canceled),
      isTrue,
    );
  });

  testWidgets('进行中的任务展示传输大小和速度', (tester) async {
    await pumpTasks(
      tester,
      const <TransferTask>[
        TransferTask(
          id: 'upload-1',
          name: '归档.zip',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.running,
          progress: 0.5,
          transferredBytes: 5 * 1024 * 1024,
          totalBytes: 10 * 1024 * 1024,
          bytesPerSecond: 2 * 1024 * 1024,
          message: '进行中',
        ),
      ],
    );

    expect(find.text('5.0 MB / 10.0 MB · 2.0 MB/s'), findsOneWidget);
  });
}
