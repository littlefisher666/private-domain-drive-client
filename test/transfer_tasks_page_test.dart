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
}
