import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:private_domain_drive_client/app/bootstrap/app_bootstrap.dart';
import 'package:private_domain_drive_client/features/transfer/domain/transfer_task.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/main.dart' as app;
import 'package:private_domain_drive_client/shared/state/app_controller.dart';

const _runOssCrudTest = bool.fromEnvironment('RUN_OSS_CRUD_TEST');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'macOS：真实 OSS 批量下载、批量删除与队列并发',
    (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 10));

      final controller = AppBootstrap.controller;
      expect(controller.isLoggedIn, isTrue);

      final originalPath = controller.currentPath;
      final runId = 'batch-qa-${DateTime.now().millisecondsSinceEpoch}';
      final runPath = 'shared/_qa/$runId/';
      final downloadDirectory =
          await Directory.systemTemp.createTemp('pdd-batch-download-');
      var testDirectoryCreated = false;

      try {
        await _ensureQaDirectory(controller, tester);
        controller.setCurrentPath('shared/_qa/');
        await controller.createFolder(runId);
        testDirectoryCreated = true;
        controller.setCurrentPath(runPath);

        final firstContent = utf8.encode('批量下载文件 A');
        final secondContent = utf8.encode('批量下载文件 B');
        final taskStart = controller.tasks.length;
        await controller.uploadBytes(fileName: 'a.txt', bytes: firstContent);
        await controller.uploadBytes(fileName: 'b.txt', bytes: secondContent);
        await _waitForTasks(controller, tester, taskStart);

        final files = await controller.listDirectory(runPath);
        final downloadItems = files.where((item) => !item.isDirectory).toList();
        expect(downloadItems.map((item) => item.name), containsAll(<String>['a.txt', 'b.txt']));

        await controller.setTransferConcurrency(1);
        final batchId = controller.enqueueDownloads(
          downloadItems,
          targetDirectory: downloadDirectory.path,
        );
        await _waitForBatch(controller, tester, batchId);

        final batchTasks =
            controller.tasks.where((task) => task.batchId == batchId).toList();
        expect(batchTasks, hasLength(2));
        expect(batchTasks.every((task) => task.status == TransferTaskStatus.success), isTrue);
        expect(batchTasks.every((task) => task.progress == 1), isTrue);
        expect(await File('${downloadDirectory.path}/a.txt').readAsBytes(), firstContent);
        expect(await File('${downloadDirectory.path}/b.txt').readAsBytes(), secondContent);

        controller.setCurrentPath(runPath);
        await controller.createFolder('资料');
        controller.setCurrentPath('$runPath资料/');
        final nestedTaskStart = controller.tasks.length;
        await controller.uploadBytes(fileName: 'nested.txt', bytes: firstContent);
        await _waitForTasks(controller, tester, nestedTaskStart);
        final nestedItems = await controller.listDirectory('$runPath资料/');
        controller.setCurrentPath(runPath);
        final rootItems = await controller.listDirectory(runPath);
        final nestedFolder = rootItems.singleWhere((item) => item.name == '资料');
        final recursive = await controller.enqueueDownloadsRecursively(
          <FileItem>[nestedFolder, nestedItems.single],
          targetDirectory: downloadDirectory.path,
        );
        await _waitForBatch(controller, tester, recursive.batchId);
        expect(recursive.fileCount, 1);
        expect(
          await File('${downloadDirectory.path}/资料/nested.txt').readAsBytes(),
          firstContent,
        );

        final preview = await controller.prepareBatchDelete(rootItems);
        expect(preview.objectCount, 4);
        final result = await controller.deleteBatch(preview);
        expect(result.failedPaths, isEmpty);
        expect(result.deletedPaths, hasLength(4));
        final remaining = await controller.listDirectory(runPath);
        expect(remaining, isEmpty);
      } finally {
        await downloadDirectory.delete(recursive: true);
        if (testDirectoryCreated) {
          try {
            await controller.deleteItem(
              FileItem(path: runPath, name: runId, isDirectory: true),
            );
          } catch (_) {
            // 不掩盖测试主体的断言；清理由下一次 QA 运行或人工检查处理。
          }
        }
        controller.setCurrentPath(originalPath);
      }
    },
    skip: !_runOssCrudTest,
  );
}

Future<void> _ensureQaDirectory(
  AppController controller,
  WidgetTester tester,
) async {
  controller.setCurrentPath('shared/');
  final rootItems = await controller.listDirectory('shared/');
  if (rootItems.any((item) => item.path == 'shared/_qa/')) return;
  await controller.createFolder('_qa');
  await tester.pump();
}

Future<void> _waitForTasks(
  AppController controller,
  WidgetTester tester,
  int startIndex,
) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (DateTime.now().isBefore(deadline)) {
    final tasks = controller.tasks.skip(startIndex).toList();
    if (tasks.isNotEmpty &&
        tasks.every((task) => _isTerminal(task.status))) {
      expect(tasks.where((task) => task.status == TransferTaskStatus.failed), isEmpty,
          reason: tasks.map((task) => task.error).join('\n'));
      return;
    }
    // 真实 OSS 请求在应用事件循环中完成；仅推进测试时钟会阻塞其状态回写。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  fail('等待传输任务超时');
}

Future<void> _waitForBatch(
  AppController controller,
  WidgetTester tester,
  String batchId,
) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (DateTime.now().isBefore(deadline)) {
    final tasks =
        controller.tasks.where((task) => task.batchId == batchId).toList();
    if (tasks.isNotEmpty &&
        tasks.every((task) => _isTerminal(task.status))) {
      expect(tasks.where((task) => task.status == TransferTaskStatus.failed), isEmpty,
          reason: tasks.map((task) => task.error).join('\n'));
      return;
    }
    // 让真实网络传输获得执行时间，再刷新测试界面。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  fail('等待批量下载超时');
}

bool _isTerminal(TransferTaskStatus status) =>
    status == TransferTaskStatus.success ||
    status == TransferTaskStatus.failed ||
    status == TransferTaskStatus.canceled;
