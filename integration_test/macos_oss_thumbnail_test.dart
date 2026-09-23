import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:private_domain_drive_client/app/bootstrap/app_bootstrap.dart';
import 'package:private_domain_drive_client/features/transfer/domain/transfer_task.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/main.dart' as app;
import 'package:private_domain_drive_client/shared/cache/disk_image_cache.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';
import 'package:private_domain_drive_client/shared/widgets/file_icon.dart';

const _runOssThumbnailTest = bool.fromEnvironment('RUN_OSS_THUMBNAIL_TEST');
const _qaAccount = String.fromEnvironment(
  'OSS_QA_ACCOUNT',
  defaultValue: 'admin',
);
const _qaPassword = String.fromEnvironment(
  'OSS_QA_PASSWORD',
  defaultValue: '123456',
);
const _existingThumbnailPath = String.fromEnvironment(
  'OSS_QA_EXISTING_THUMBNAIL_PATH',
);

final Map<String, List<int>> _imageFixtures = <String, List<int>>{
  'qa-thumbnail.png': base64Decode(
    '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',
  ),
  'qa-thumbnail.jpg': base64Decode(
    '/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQA'
    'AAABAAAAgKADAAQAAAABAAAAgAAAAAD/wAARCACAAIADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL'
    '/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3'
    'ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXG'
    'x8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgEC'
    'BAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZH'
    'SElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU'
    '1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9sAQwACAgICAgIDAgIDBQMDAwUGBQUFBQYIBgYGBgYICggICAgICAoKCgoKCgoKDAwM'
    'DAwMDg4ODg4PDw8PDw8PDw8P/9sAQwECAgIEBAQHBAQHEAsJCxAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ'
    'EBAQEBAQEBAQEBAQ/90ABAAI/9oADAMBAAIRAxEAPwD9/KKKKACijOOtN3Z6DNADqKT5vak+b2oAdRTfm9qX5vagBaKT5vak+b2o'
    'AdRTfm9qPm9BQA6im7sdRTgQelABRRRQB//Q/fykYhQSegparTNumih/vZY/Qf8A16AJVBb52/AelSUUUAFFFFABRRSEhQSTgDvQ'
    'AtFfNXjP49tpmrNp/hS3hvIIMrJPNuKu/wD0z2svyj1PXtxyeR/4aK8Wf9A6y/75l/8AjlfW4fgnMKkFUUEr93ZnwmL8R8po1JUp'
    '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',
  ),
  'qa-thumbnail.gif': base64Decode(
    'R0lGODdhgACAAOYAAAAAAAoKCiIiIjAwMEBAQBNOlU5OThFRlhBTmA5VmQBXmwVanAlcnRJdnl5eXhxfnx5gnyBhoGFhYUxypyFz'
    's1Fzp050qFJ1qHZ2dh54t1Z5qiJ8u3x8fCKAvyOEwYSEhEOKwYqKipaWlpubm6Ojo6urq7S0tDK18zS59jm69j67+EO8+E29+L6+'
    'vsTExFbF+L3F177G2FvH+F3I+GHJ+MrKysTL2mvM+XTO+n7P+YDP+YPQ+tTU1I/V/JDW/MfX69zc3L/h/eLi4sTj/cnl/cfo/enp'
    '6c3q/efq8NPs/urs8dru/d7w/e7w9OTz/vT09er1/vT1+PH4/v///wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAACH5BAkAAFQALAAAAACAAIAAAAf/gFSCg4SFhoeIiYqLjI2Oj5CRkpOUlZaXmJmam5ydnp+g'
    'oaKjpKWmp6ipqqusra6vsLGys7S1tregU7q6T0+7v8DBwsPEvb5TvbiJx8TNzs/Qz7fR1NXW0bLX2tvcuq7M3eHizU+r4+fow6np'
    '7O1Tp+7x6KXy9eOj9vnhoUb6/trlPv0baO0TOIIIm3lKyNBZp4MNI/LiJDGYkx06MmrcmKOjx486pOzbVPGXExw0UqpMOaOly5cy'
    'ZNBIIm5Tv5JTnNxYyfOlzxkybtAUZ0QTRIY6efb86XLmuYCYcEJBqXQl05Y0lqTTVPJk1aU/hbLjKjHpV6s/nY7NJBHKzrNo/31q'
    'bQcEE4+IU+GCxTqXLiYgDc3qVflSbDwhmIQgfTuYMNah8YpeUozQbWOwfQ8nrkz1MssZNzJH3jxQsGcaoCHXk2yJsj/Tp9XmY13J'
    'db68sVWKXo3p5u3OsUMPpE3Jdz3Yng3/Iz7JeDzknlX7Yy7JeTvcubMmpB7Jejqv2ZUT5A7J+znojcWP7x3PcnbZ29lfBx579/pL'
    '5ruBz60+Pn526A3Wn3+W5KeNe9nZR2AlBlqDXW4KLljceYwFJ51E5D3SYDQB6jVgRBk6suEzCEKI0y8hNjJiMw+eJtyJu6TIyIrD'
    'dAjXDUfAiKJ82tgI14UnyrgIjcC0eFqEUzDhw/+SPvTg5JNQRumkDyKFI6QiRO5i5GUf6rLEDVcBFdOYZAbFxDhXJpJlThW6mCMx'
    'S6B2VZl0vkgUj9Qc8R58wcQZpph0xkTDmeekiciaUySRYDNMgBlmoGPS4EQ6hh6C6BR6JgfkLn4+CqmZ7FRqyKVTFMHlm8N0Ouen'
    'dqIjaiGkYtrYprowIeeqkA7qzquExJqoXkg2+uenMk26K57bZKpUl1MsscILnkLaaqjIbmMqTzg2s4QKKaQA7U/ETkvtf+MomxKt'
    'zXLbbQoy+ETsDMbKw+sgvv6iLJJLsLAuCiiw61K48cpbbTdFZAunuvwm7C2ggYp7LLnoVJkqtwlX3O//C6wiSenA8TibgsUWsxso'
    'vMtx3E6+IKfsbZk3BDybyelsm/LMKGAck8O8TZaPzDTPjLF297VmD8o90yyDy9ORJs8QHxed8gkgKCHhJLbFE0TTTid8ggcMWIAE'
    'QvMKUnU8TGfN7wkbMKC2BU0EXZs/RGDd8wkZqG23BlEMp3Q+Zc+dtt12WyB10jr/czXNJ3SQAOCAXzD4y4X/M8TMaCdg+eKMd31U'
    'O2FTMXY+cVt8AgUHIHA55oAvoMHmG18CGEJ9o4D2AbSjzvgCuE/w+GiuM3Q42gUcYPvtuOPueD2I9c7Q5BQUkHnqxUc/Qd6aXXJX'
    'Qz888Lza0XeP++rx1BVV/0QwRPC89+jr7g4PbEkEg/Z2oy//AoK3Q5ZENjTAwPz8V0D9PO2riA0ewD/+HQ+AmGAdQWAAgQLObwJf'
    'GwdUIlcRGDTAgehTgPrudL+S5A+D0VOACC/wP260gCQwisEFMSjCFiqgAgqEBic+pyPCobCGCPFEvXBojc4dgocDAcX1gGiP5H1i'
    'h0QsxihimERu0KOJ7BiBKZgIxWhI8RRIJOIETzHEKlpDfKzIYpBCAIsQ0NCLuxDCFWdRAiFQUUdPEIIJlEGIEbSgBjwAgh73qEch'
    '+PGPgAykIAdJyD/ycY88qEEL1kjHRjrykZCMpCQnSclKWvKSmMykJjfJyU568geToAxlIwMBADs=',
  ),
  'qa-thumbnail.webp': base64Decode(
    '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',
  ),
  'qa-thumbnail.heic': base64Decode(
    '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',
  ),
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'macOS：真实 OSS 图片格式、滚动、缓存失效与未登录回退',
    (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 10));

      final controller = AppBootstrap.controller;
      await _ensureLoggedIn(controller);
      expect(controller.capabilities.upload, isTrue);
      expect(controller.capabilities.delete, isTrue);

      final originalPath = controller.currentPath;
      final runId = 'thumbnail-${DateTime.now().millisecondsSinceEpoch}';
      final runPath = 'shared/_qa/$runId/';
      final uploadDirectory =
          await Directory.systemTemp.createTemp('pdd-thumbnail-upload-');
      var uploadIndex = 0;
      Future<void> enqueueUpload(
        String fileName,
        List<int> bytes, {
        String? targetPath,
      }) async {
        final source = File(
          '${uploadDirectory.path}/${uploadIndex++}-$fileName',
        );
        await source.writeAsBytes(bytes);
        await controller.uploadFile(
          fileName: fileName,
          localPath: source.path,
          fileSize: bytes.length,
          targetPath: targetPath,
        );
      }

      var testDirectoryCreated = false;
      var loggedOutForFallback = false;

      try {
        await _ensureQaDirectory(controller, tester);
        controller.setCurrentPath('shared/_qa/');
        await controller.createFolder(runId);
        testDirectoryCreated = true;
        controller.setCurrentPath(runPath);

        final uploadStart = controller.tasks.length;
        for (final entry in _imageFixtures.entries) {
          await enqueueUpload(entry.key, entry.value);
        }
        for (var index = 0; index < 13; index++) {
          await enqueueUpload(
            'scroll-${index.toString().padLeft(2, '0')}.png',
            _imageFixtures['qa-thumbnail.png']!,
          );
        }
        await _waitForTasks(controller, tester, uploadStart);

        var items = await controller.listDirectory(runPath);
        expect(items.where((item) => !item.isDirectory), hasLength(18));

        for (final name in _imageFixtures.keys) {
          final item = items.singleWhere((candidate) => candidate.name == name);
          final thumbnail = await controller.loadThumbnail(item);
          expect(thumbnail, isNotEmpty, reason: '$name 未返回缩略图字节');
          final codec = await ui.instantiateImageCodec(
            Uint8List.fromList(thumbnail),
          );
          final frame = await codec.getNextFrame();
          expect(frame.image.width, lessThanOrEqualTo(ImageThumbnailSpec.size));
          expect(
              frame.image.height, lessThanOrEqualTo(ImageThumbnailSpec.size));
          frame.image.dispose();
          codec.dispose();
        }

        // 真实用户对象键常包含中文目录、中文文件名、空格和大写扩展名；
        // 该场景必须走完整的原生 OSS 图片处理链路。
        const localizedDirectory = '相册';
        const localizedFileName = '8寸雅典摆台 XXJ_4477.JPG';
        final localizedPath = '$runPath$localizedDirectory/';
        await controller.createFolder(localizedDirectory);
        final localizedUploadStart = controller.tasks.length;
        await enqueueUpload(
          localizedFileName,
          _imageFixtures['qa-thumbnail.jpg']!,
          targetPath: localizedPath,
        );
        await _waitForTasks(controller, tester, localizedUploadStart);
        final localizedItems = await controller.listDirectory(localizedPath);
        final localizedItem = localizedItems.singleWhere(
          (item) => item.name == localizedFileName,
        );
        final localizedThumbnail =
            await controller.loadThumbnail(localizedItem);
        expect(localizedThumbnail, isNotEmpty, reason: '中文路径图片未返回缩略图字节');
        final localizedCodec = await ui.instantiateImageCodec(
          Uint8List.fromList(localizedThumbnail),
        );
        final localizedFrame = await localizedCodec.getNextFrame();
        expect(
          localizedFrame.image.width,
          lessThanOrEqualTo(ImageThumbnailSpec.size),
        );
        expect(
          localizedFrame.image.height,
          lessThanOrEqualTo(ImageThumbnailSpec.size),
        );
        localizedFrame.image.dispose();
        localizedCodec.dispose();

        if (_existingThumbnailPath.isNotEmpty) {
          final existingName = _existingThumbnailPath
              .split('/')
              .where((segment) => segment.isNotEmpty)
              .last;
          final existingThumbnail = await controller.loadThumbnail(
            FileItem(
              path: _existingThumbnailPath,
              name: existingName,
              isDirectory: false,
            ),
          );
          expect(existingThumbnail, isNotEmpty, reason: '指定的既有 OSS 图片未返回缩略图字节');
          final existingCodec = await ui.instantiateImageCodec(
            Uint8List.fromList(existingThumbnail),
          );
          final existingFrame = await existingCodec.getNextFrame();
          expect(
            existingFrame.image.width,
            lessThanOrEqualTo(ImageThumbnailSpec.size),
          );
          expect(
            existingFrame.image.height,
            lessThanOrEqualTo(ImageThumbnailSpec.size),
          );
          existingFrame.image.dispose();
          existingCodec.dispose();
        }

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 500,
                child: GridView.builder(
                  key: const Key('oss-thumbnail-grid'),
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.1,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) => FileTypeThumbnail(
                    item: items[index],
                    loader: controller.loadThumbnail,
                    height: double.infinity,
                    cacheNamespace: controller.thumbnailCacheNamespace,
                  ),
                ),
              ),
            ),
          ),
        );
        await _waitForVisibleImages(tester, minimum: 4);
        await tester.drag(
          find.byKey(const Key('oss-thumbnail-grid')),
          const Offset(0, -700),
        );
        await tester.pump();
        await _waitForVisibleImages(tester, minimum: 4);
        final scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: find.byKey(const Key('oss-thumbnail-grid')),
            matching: find.byType(Scrollable),
          ),
        );
        expect(scrollable.position.pixels, greaterThan(0));

        final original = items.singleWhere(
          (item) => item.name == 'qa-thumbnail.png',
        );
        var realLoaderCalls = 0;
        Future<List<int>> countingLoader(FileItem item) async {
          realLoaderCalls++;
          return controller.loadThumbnail(item);
        }

        // 缩略图组件不再跨挂载持有内存缓存，重复展示由磁盘缓存承担：
        // 第二次挂载会再次调用 loader，但 controller 层直接命中磁盘缓存。
        await _pumpSingleThumbnail(
          tester,
          item: original,
          loader: countingLoader,
          namespace: controller.thumbnailCacheNamespace,
        );
        expect(realLoaderCalls, 1);
        await _waitForDiskCachedThumbnail(controller, original);
        await _pumpSingleThumbnail(
          tester,
          item: original,
          loader: countingLoader,
          namespace: controller.thumbnailCacheNamespace,
        );
        expect(realLoaderCalls, 2);

        final replacement = <int>[
          ..._imageFixtures['qa-thumbnail.png']!,
          0,
        ];
        final replacementStart = controller.tasks.length;
        await enqueueUpload(
          'qa-thumbnail.png',
          replacement,
          targetPath: runPath,
        );
        await _waitForTasks(controller, tester, replacementStart);
        items = await controller.listDirectory(runPath);
        final updated = items.singleWhere(
          (item) => item.name == 'qa-thumbnail.png',
        );
        expect(updated.objectVersionToken, isNot(original.objectVersionToken));
        await _pumpSingleThumbnail(
          tester,
          item: updated,
          loader: countingLoader,
          namespace: controller.thumbnailCacheNamespace,
        );
        expect(realLoaderCalls, 3);

        await controller.logout();
        loggedOutForFallback = true;
        await tester.pumpWidget(
          MaterialApp(
            home: FileTypeThumbnail(
              item: updated,
              loader: controller.loadThumbnail,
              cacheNamespace: 'logged-out',
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
        expect(find.byIcon(Icons.image_outlined), findsOneWidget);
        expect(find.byType(Image), findsNothing);

        await _ensureLoggedIn(controller);
        loggedOutForFallback = false;
      } finally {
        await uploadDirectory.delete(recursive: true);
        if (loggedOutForFallback || !controller.isLoggedIn) {
          await _ensureLoggedIn(controller);
        }
        if (testDirectoryCreated) {
          try {
            await controller.deleteItem(
              FileItem(path: runPath, name: runId, isDirectory: true),
            );
          } catch (_) {
            // 不掩盖测试主体断言；失败时保留隔离目录供人工清理。
          }
        }
        controller.setCurrentPath(originalPath);
      }
    },
    skip: !_runOssThumbnailTest,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _ensureLoggedIn(AppController controller) async {
  if (controller.isLoggedIn) return;
  final result = await controller.login(
    account: _qaAccount,
    password: _qaPassword,
  );
  expect(result.ok, isTrue, reason: result.message);
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
    if (tasks.isNotEmpty && tasks.every((task) => _isTerminal(task.status))) {
      expect(
        tasks.where((task) => task.status == TransferTaskStatus.failed),
        isEmpty,
        reason: tasks.map((task) => task.error).join('\n'),
      );
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  fail('等待 OSS 图片上传任务超时');
}

Future<void> _waitForVisibleImages(
  WidgetTester tester, {
  required int minimum,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
    if (find.byType(Image).evaluate().length >= minimum) return;
  }
  fail('等待可见缩略图解码超时');
}

Future<void> _pumpSingleThumbnail(
  WidgetTester tester, {
  required FileItem item,
  required Future<List<int>> Function(FileItem) loader,
  required String namespace,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: FileTypeThumbnail(
        item: item,
        loader: loader,
        cacheNamespace: namespace,
      ),
    ),
  );
  await _waitForVisibleImages(tester, minimum: 1);
}

/// 缩略图写入磁盘缓存是 fire-and-forget 的，轮询等待其落盘。
Future<void> _waitForDiskCachedThumbnail(
  AppController controller,
  FileItem item,
) async {
  final cacheKey = DiskImageCache.cacheKey(
    namespace: controller.thumbnailCacheNamespace,
    path: item.path,
    versionToken: item.objectVersionToken,
    process: ImageThumbnailSpec.process(),
  );
  for (var attempt = 0; attempt < 50; attempt++) {
    final cached = await DiskImageCache.instance.read(
      DiskImageCacheKind.thumbnails,
      cacheKey,
    );
    if (cached != null) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('缩略图未在限时内写入磁盘缓存：${item.path}');
}

bool _isTerminal(TransferTaskStatus status) =>
    status == TransferTaskStatus.success ||
    status == TransferTaskStatus.failed ||
    status == TransferTaskStatus.canceled;
