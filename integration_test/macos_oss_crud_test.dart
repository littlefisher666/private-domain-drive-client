import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:private_domain_drive_client/app/bootstrap/app_bootstrap.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/main.dart' as app;

const _runOssCrudTest = bool.fromEnvironment('RUN_OSS_CRUD_TEST');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'macOS：OSS 临时目录 CRUD、同名覆盖与大文件传输',
    (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 10));

      final controller = AppBootstrap.controller;
      expect(controller.isLoggedIn, isTrue);

      final originalPath = controller.currentPath;
      final runId = 'oss-check-${DateTime.now().millisecondsSinceEpoch}';
      final runPath = 'shared/_qa/$runId/';
      var uploadedItem = FileItem(
        path: '$runPath中文验证.txt',
        name: '中文验证.txt',
        isDirectory: false,
      );
      var testDirectoryCreated = false;
      var uploaded = false;
      var largeFileUploaded = false;
      final largeFile = FileItem(
        path: '$runPath大文件.bin',
        name: '大文件.bin',
        isDirectory: false,
      );

      try {
        controller.setCurrentPath('shared/');
        await controller.createFolder('_qa');
        controller.setCurrentPath('shared/_qa/');
        await controller.createFolder(runId);
        testDirectoryCreated = true;
        controller.setCurrentPath(runPath);

        final content = utf8.encode('Private Domain Drive OSS CRUD 验证');
        await controller.uploadBytes(
            fileName: uploadedItem.name, bytes: content);
        uploaded = true;

        final uploadedItems = await controller.listDirectory(runPath);
        expect(uploadedItems.map((item) => item.name),
            contains(uploadedItem.name));

        final downloaded = await controller.downloadBytes(uploadedItem);
        expect(downloaded, content);

        final overwrittenContent = utf8.encode('同名文件应覆盖原内容');
        await controller.uploadBytes(
          fileName: uploadedItem.name,
          bytes: overwrittenContent,
        );
        final overwritten = await controller.downloadBytes(uploadedItem);
        expect(overwritten, overwrittenContent);
        final sameNameItems = await controller.listDirectory(runPath);
        expect(
          sameNameItems.where((item) => item.name == uploadedItem.name),
          hasLength(1),
        );

        await controller.renameItem(uploadedItem, '已重命名.txt');
        uploadedItem = FileItem(
          path: '$runPath已重命名.txt',
          name: '已重命名.txt',
          isDirectory: false,
        );
        final renamedItems = await controller.listDirectory(runPath);
        expect(
            renamedItems.map((item) => item.name), contains(uploadedItem.name));

        final largeFileBytes = List<int>.filled(11 * 1024 * 1024, 0x5a);
        await controller.uploadBytes(
          fileName: largeFile.name,
          bytes: largeFileBytes,
        );
        largeFileUploaded = true;
        final itemsWithLargeFile = await controller.listDirectory(runPath);
        expect(
          itemsWithLargeFile
              .singleWhere((item) => item.name == largeFile.name)
              .size,
          largeFileBytes.length,
        );

        const nestedFolderName = '待递归删除';
        final nestedFolderPath = '$runPath$nestedFolderName/';
        await controller.createFolder(nestedFolderName);
        await controller.uploadBytes(
          fileName: '子文件.txt',
          bytes: utf8.encode('递归删除验证'),
          targetPath: nestedFolderPath,
        );
        await controller.deleteItem(
          FileItem(
            path: nestedFolderPath,
            name: nestedFolderName,
            isDirectory: true,
          ),
        );
        final itemsAfterFolderDelete = await controller.listDirectory(runPath);
        expect(
          itemsAfterFolderDelete.map((item) => item.path),
          isNot(contains(nestedFolderPath)),
        );

        await controller.deleteItem(uploadedItem);
        uploaded = false;
        await controller.deleteItem(largeFile);
        largeFileUploaded = false;
        final remainingItems = await controller.listDirectory(runPath);
        expect(remainingItems, isEmpty);
      } finally {
        if (uploaded) {
          await controller.deleteItem(uploadedItem);
        }
        if (largeFileUploaded) {
          await controller.deleteItem(largeFile);
        }
        if (testDirectoryCreated) {
          await controller.deleteItem(
            FileItem(path: runPath, name: runId, isDirectory: true),
          );
        }
        controller.setCurrentPath(originalPath);
      }
    },
    skip: !_runOssCrudTest,
  );
}
