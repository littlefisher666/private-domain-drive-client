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

  Future<AppController> pumpMobileTasks(
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
            body: TransferTasksPage(embedded: true),
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

  testWidgets('移动端统计头部固定置顶并展示字节进度与全局速度', (tester) async {
    final tasks = <TransferTask>[
      const TransferTask(
        id: 'running-1',
        name: '归档.zip',
        type: TransferTaskType.upload,
        status: TransferTaskStatus.running,
        progress: 0.5,
        transferredBytes: 5 * 1024 * 1024,
        totalBytes: 10 * 1024 * 1024,
        bytesPerSecond: 2 * 1024 * 1024,
        message: '进行中',
      ),
      const TransferTask(
        id: 'pending-1',
        name: '等待.zip',
        type: TransferTaskType.upload,
        status: TransferTaskStatus.pending,
        progress: 0,
        transferredBytes: 1024 * 1024,
        totalBytes: 4 * 1024 * 1024,
      ),
      for (var index = 0; index < 20; index++)
        TransferTask(
          id: 'done-$index',
          name: '已完成-$index.zip',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.success,
          progress: 1,
        ),
    ];
    await pumpMobileTasks(tester, tasks);

    // 直接注入任务不经过队列，进行中/等待计数为 0；统计口径来自任务字段。
    const statsText = '0 进行中 · 0 等待 · 6.0 MB / 14.0 MB · 2.0 MB/s';
    expect(find.text(statsText), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    // 长列表滚动后统计行仍固定在屏幕内。
    expect(
      tester.getTopLeft(find.text(statsText)).dy,
      greaterThanOrEqualTo(0),
    );
    expect(find.text(statsText), findsOneWidget);
  });

  testWidgets('移动端进行中任务展示大小与速度', (tester) async {
    await pumpMobileTasks(
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

    expect(
      find.text('50% · 5.0 MB / 10.0 MB · 2.0 MB/s · 进行中'),
      findsOneWidget,
    );
  });

  testWidgets('移动端总字节未知时仅展示已传输量', (tester) async {
    await pumpMobileTasks(
      tester,
      const <TransferTask>[
        TransferTask(
          id: 'upload-1',
          name: '未知大小.bin',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.running,
          progress: 0,
          transferredBytes: 2048,
          message: '进行中',
        ),
      ],
    );

    expect(find.text('0% · 2.0 KB · 进行中'), findsOneWidget);
  });

  testWidgets('任务按状态优先级排列，同状态内新任务在前', (tester) async {
    await pumpMobileTasks(
      tester,
      <TransferTask>[
        const TransferTask(
          id: 'done-old',
          name: '最早完成.txt',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.success,
          progress: 1,
        ),
        const TransferTask(
          id: 'pending-old',
          name: '较早等待.txt',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.pending,
          progress: 0,
        ),
        const TransferTask(
          id: 'running',
          name: '进行中.txt',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.running,
          progress: 0.4,
        ),
        const TransferTask(
          id: 'pending-new',
          name: '最新等待.txt',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.pending,
          progress: 0,
        ),
        const TransferTask(
          id: 'done-new',
          name: '最近完成.txt',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.success,
          progress: 1,
        ),
      ],
    );

    // 卡片元素按列表布局顺序返回，依次取卡片标题。
    final names = find.byType(Card).evaluate().map((element) {
      final text = find
          .descendant(
            of: find.byElementPredicate((e) => e == element),
            matching: find.byType(Text),
          )
          .evaluate();
      return (text.first.widget as Text).data;
    }).toList();
    expect(names, <String>[
      '进行中.txt',
      '最新等待.txt',
      '较早等待.txt',
      '最近完成.txt',
      '最早完成.txt',
    ]);
  });

  testWidgets('移动端空列表展示空状态', (tester) async {
    await pumpMobileTasks(tester, const <TransferTask>[]);

    expect(find.text('暂无传输任务'), findsOneWidget);
  });
}
