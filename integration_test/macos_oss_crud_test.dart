import 'dart:async';
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
    'macOS：真实 OSS 完整对象操作、传输进度、速度与取消',
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
      final uploadDirectory =
          await Directory.systemTemp.createTemp('pdd-batch-upload-');
      var testDirectoryCreated = false;
      final progressSamples = <int>{};
      final speedSamples = <double>[];
      var cancelRequested = false;
      String? progressTaskId;
      String? cancelTaskId;

      void observeTransfers() {
        for (final task in controller.tasks) {
          if (task.id == progressTaskId) {
            final total = task.totalBytes ?? 0;
            if (task.transferredBytes > 0 && task.transferredBytes < total) {
              progressSamples.add(task.transferredBytes);
            }
            final speed = task.bytesPerSecond;
            if (speed != null && speed.isFinite && speed > 0) {
              speedSamples.add(speed);
            }
          }
          if (task.id == cancelTaskId &&
              !cancelRequested &&
              task.status == TransferTaskStatus.running &&
              task.transferredBytes > 0 &&
              task.transferredBytes < (task.totalBytes ?? 0)) {
            cancelRequested = true;
            scheduleMicrotask(() => controller.cancelTask(task.id));
          }
        }
      }

      controller.tasksListenable.addListener(observeTransfers);

      try {
        await _ensureQaDirectory(controller, tester);
        controller.setCurrentPath('shared/_qa/');
        await controller.createFolder(runId);
        testDirectoryCreated = true;
        controller.setCurrentPath(runPath);

        final firstContent = utf8.encode('批量下载文件 A');
        final secondContent = utf8.encode('批量下载文件 B');
        final firstSource = File('${uploadDirectory.path}/source-a.txt');
        final secondSource = File('${uploadDirectory.path}/source-b.txt');
        final queuedSource = File('${uploadDirectory.path}/queued.txt');
        final progressSource = File('${uploadDirectory.path}/progress.bin');
        final cancelSource = File('${uploadDirectory.path}/cancel.bin');
        await firstSource.writeAsBytes(firstContent);
        await secondSource.writeAsBytes(secondContent);
        await queuedSource.writeAsBytes(utf8.encode('排队后仍可读取的文件'));
        await _writeRepeatedFile(progressSource, 128 * 1024 * 1024);
        await _writeRepeatedFile(cancelSource, 256 * 1024 * 1024);

        // 强制刷新一次 STS，并立刻通过真实列表请求验证新凭证已配置到 Swift SDK。
        await controller.ensureFreshCredentials(force: true);
        await controller.listDirectory(runPath);

        final taskStart = controller.tasks.length;
        await controller.uploadFile(
          fileName: 'a.txt',
          localPath: firstSource.path,
          fileSize: firstContent.length,
        );
        await controller.uploadFile(
          fileName: 'b.txt',
          localPath: secondSource.path,
          fileSize: secondContent.length,
        );

        await controller.setTransferConcurrency(1);
        await controller.uploadFile(
          fileName: 'large-progress.bin',
          localPath: progressSource.path,
          fileSize: await progressSource.length(),
        );
        progressTaskId = controller.tasks.last.id;
        await controller.uploadFile(
          fileName: 'queued.txt',
          localPath: queuedSource.path,
          fileSize: await queuedSource.length(),
        );
        final queuedTaskId = controller.tasks.last.id;
        expect(
          controller.tasks
              .singleWhere((task) => task.id == queuedTaskId)
              .status,
          TransferTaskStatus.pending,
        );
        await _waitForTasks(controller, tester, taskStart,
            timeout: const Duration(minutes: 5));

        expect(progressSamples.length, greaterThanOrEqualTo(2),
            reason: '大文件上传应展示多个 0% 到 100% 之间的真实进度点');
        expect(speedSamples, isNotEmpty, reason: '持续超过速度窗口的大文件上传应展示真实速度');
        expect(
          speedSamples.every((speed) => speed > 0 && speed.isFinite),
          isTrue,
        );

        final cancelStart = controller.tasks.length;
        await controller.uploadFile(
          fileName: 'canceled.bin',
          localPath: cancelSource.path,
          fileSize: await cancelSource.length(),
        );
        cancelTaskId = controller.tasks.last.id;
        await _waitForTasks(controller, tester, cancelStart,
            allowCanceled: true, timeout: const Duration(minutes: 5));
        final canceledTask =
            controller.tasks.singleWhere((task) => task.id == cancelTaskId);
        expect(cancelRequested, isTrue, reason: '测试必须在原生上传运行中发起取消');
        expect(canceledTask.status, TransferTaskStatus.canceled);

        var files = await controller.listDirectory(runPath);
        final downloadItems = files.where((item) => !item.isDirectory).toList();
        expect(
            downloadItems.map((item) => item.name),
            containsAll(<String>[
              'a.txt',
              'b.txt',
              'large-progress.bin',
              'queued.txt',
            ]));
        expect(
          downloadItems.map((item) => item.name),
          isNot(contains('canceled.bin')),
        );

        final secondItem =
            downloadItems.singleWhere((item) => item.name == 'b.txt');
        await controller.renameItem(secondItem, 'b-renamed.txt');
        files = await controller.listDirectory(runPath);
        expect(files.map((item) => item.name), contains('b-renamed.txt'));
        expect(files.map((item) => item.name), isNot(contains('b.txt')));

        final batchId = controller.enqueueDownloads(
          files.where(
            (item) => item.name == 'a.txt' || item.name == 'b-renamed.txt',
          ),
          targetDirectory: downloadDirectory.path,
        );
        await _waitForBatch(controller, tester, batchId);

        final batchTasks =
            controller.tasks.where((task) => task.batchId == batchId).toList();
        expect(batchTasks, hasLength(2));
        expect(
            batchTasks
                .every((task) => task.status == TransferTaskStatus.success),
            isTrue);
        expect(batchTasks.every((task) => task.progress == 1), isTrue);
        expect(await File('${downloadDirectory.path}/a.txt').readAsBytes(),
            firstContent);
        expect(
          await File('${downloadDirectory.path}/b-renamed.txt').readAsBytes(),
          secondContent,
        );

        controller.setCurrentPath(runPath);
        await controller.createFolder('资料');
        controller.setCurrentPath('$runPath资料/');
        final nestedTaskStart = controller.tasks.length;
        await controller.uploadFile(
          fileName: 'nested.txt',
          localPath: firstSource.path,
          fileSize: firstContent.length,
        );
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
        expect(preview.objectCount, greaterThanOrEqualTo(6));
        final result = await controller.deleteBatch(preview);
        expect(result.failedPaths, isEmpty);
        expect(result.deletedPaths, hasLength(preview.objectCount));
        final remaining = await controller.listDirectory(runPath);
        expect(remaining, isEmpty);
      } finally {
        controller.tasksListenable.removeListener(observeTransfers);
        await downloadDirectory.delete(recursive: true);
        await uploadDirectory.delete(recursive: true);
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
  int startIndex, {
  Duration timeout = const Duration(minutes: 2),
  bool allowCanceled = false,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final tasks = controller.tasks.skip(startIndex).toList();
    if (tasks.isNotEmpty && tasks.every((task) => _isTerminal(task.status))) {
      expect(tasks.where((task) => task.status == TransferTaskStatus.failed),
          isEmpty,
          reason: tasks.map((task) => task.error).join('\n'));
      if (!allowCanceled) {
        expect(
          tasks.where((task) => task.status == TransferTaskStatus.canceled),
          isEmpty,
        );
      }
      return;
    }
    // 真实 OSS 请求在应用事件循环中完成；仅推进测试时钟会阻塞其状态回写。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  fail('等待传输任务超时');
}

Future<void> _writeRepeatedFile(File file, int size) async {
  final handle = await file.open(mode: FileMode.write);
  final chunk = List<int>.filled(1024 * 1024, 0x5a, growable: false);
  try {
    var written = 0;
    while (written < size) {
      final count = (size - written).clamp(0, chunk.length);
      await handle.writeFrom(chunk, 0, count);
      written += count;
    }
  } finally {
    await handle.close();
  }
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
    if (tasks.isNotEmpty && tasks.every((task) => _isTerminal(task.status))) {
      expect(tasks.where((task) => task.status == TransferTaskStatus.failed),
          isEmpty,
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
