import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/transfer/domain/transfer_task.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/domain/recycle_bin_entry.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';

void main() {
  group('AppController', () {
    test('登录失败会返回明确错误', () async {
      final controller =
          AppController(sessionRepository: MemorySessionRepository());

      final result = await controller.login(account: 'admin', password: '错误口令');

      expect(result.ok, isFalse);
      expect(result.message, '账号或口令错误');
    });

    test('启动后会恢复本地传输历史', () async {
      const completedTask = TransferTask(
        id: 'download-history-1',
        name: '已下载文件.jpg',
        type: TransferTaskType.download,
        status: TransferTaskStatus.success,
        progress: 1,
        target: '/Users/test/Downloads/已下载文件.jpg',
        totalBytes: 1024,
      );
      const failedTask = TransferTask(
        id: 'upload-failed-1',
        name: '未完成文件.jpg',
        type: TransferTaskType.upload,
        status: TransferTaskStatus.failed,
        progress: 0.5,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        'transfer_history:v1': jsonEncode(<Map<String, Object?>>[
          completedTask.toJson(),
          failedTask.toJson(),
        ]),
      });
      final controller =
          AppController(sessionRepository: MemorySessionRepository());

      await controller.bootstrap();

      expect(controller.tasks, hasLength(1));
      expect(controller.tasks.single.id, completedTask.id);
      expect(controller.tasks.single.status, TransferTaskStatus.success);
      expect(controller.tasks.single.target, completedTask.target);
      controller.dispose();
      await (await SharedPreferences.getInstance())
          .remove('transfer_history:v1');
    });

    test('启动后恢复显示模式，并保存新的选择', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'theme_mode': 'dark',
      });
      final controller =
          AppController(sessionRepository: MemorySessionRepository());

      await controller.bootstrap();
      expect(controller.themeMode, ThemeMode.dark);

      await controller.setThemeMode(ThemeMode.light);
      expect(
        (await SharedPreferences.getInstance()).getString('theme_mode'),
        'light',
      );
      controller.dispose();
    });

    test('启动后恢复缩略图尺寸，并保存新的选择', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'thumbnail_size': 'large',
      });
      final controller =
          AppController(sessionRepository: MemorySessionRepository());

      await controller.bootstrap();
      expect(controller.thumbnailSize, ThumbnailSize.large);

      await controller.setThumbnailSize(ThumbnailSize.small);
      expect(
        (await SharedPreferences.getInstance()).getString('thumbnail_size'),
        'small',
      );
      controller.dispose();
    });

    test('无效缩略图尺寸偏好会使用中档', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'thumbnail_size': 'extra-large',
      });
      final controller =
          AppController(sessionRepository: MemorySessionRepository());

      await controller.bootstrap();

      expect(controller.thumbnailSize, ThumbnailSize.medium);
      controller.dispose();
    });

    test('目录浏览会记录目录树并支持返回上级', () async {
      final oss = _FakeOssClient()
        ..itemsByPath['shared/'] = const <FileItem>[
          FileItem(path: 'shared/相册/', name: '相册', isDirectory: true),
        ];
      final controller = await _controller(oss: oss);

      final items = await controller.listDirectory();
      controller.setCurrentPath('shared/相册');

      expect(items.single.name, '相册');
      expect(controller.sidebarDirectories, <String>['shared/相册/']);
      expect(controller.parentPath(controller.currentPath), 'shared/');
    });

    test('首次加载根目录会通知侧栏刷新', () async {
      final oss = _FakeOssClient()
        ..itemsByPath['shared/'] = const <FileItem>[
          FileItem(path: 'shared/相册/', name: '相册', isDirectory: true),
        ];
      final controller = await _controller(oss: oss);
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.listDirectory();

      expect(notifications, 1);
      expect(controller.sidebarDirectories, <String>['shared/相册/']);
    });

    test('新建文件夹会校验空名称并使用当前目录', () async {
      final oss = _FakeOssClient();
      final controller = await _controller(oss: oss);

      await expectLater(
          controller.createFolder('  '), throwsA(isA<StateError>()));
      await controller.createFolder('资料');

      expect(oss.createdFolders, <String>['shared/资料/']);
      expect(controller.treeRevision, 1);
    });

    test('重命名通过复制后删除完成，并刷新树版本', () async {
      final oss = _FakeOssClient();
      final controller = await _controller(oss: oss);
      const item =
          FileItem(path: 'shared/旧名.txt', name: '旧名.txt', isDirectory: false);

      await controller.renameItem(item, '新名.txt');

      expect(
          oss.copies, <(String, String)>[('shared/旧名.txt', 'shared/新名.txt')]);
      expect(oss.deleted, <String>['shared/旧名.txt']);
      expect(controller.treeRevision, 1);
    });

    test('删除选中项后会清空选中状态', () async {
      final oss = _FakeOssClient();
      final controller = await _controller(oss: oss);
      const item =
          FileItem(path: 'shared/删除我.txt', name: '删除我.txt', isDirectory: false);
      controller.selectItem(item);

      await controller.deleteItem(item);

      expect(oss.deleted, <String>['shared/删除我.txt']);
      expect(controller.selectedItem, isNull);
    });

    test('恢复时同名路径会使用已还原名称且不覆盖现有对象', () async {
      final oss = _FakeOssClient()..existingPaths.add('shared/资料.txt');
      final controller = await _controller(oss: oss);
      final entry = RecycleBinEntry(
        id: 'batch-1',
        name: '资料.txt',
        originalPath: 'shared/资料.txt',
        isDirectory: false,
        deletedAt: DateTime(2026, 9, 20),
        objects: const <String, String>{
          'shared/资料.txt': 'shared/.trash/batch-1/payload/资料.txt',
        },
      );

      await controller.restoreRecycleBinEntry(entry);

      expect(
          oss.copies,
          contains((
            'shared/.trash/batch-1/payload/资料.txt',
            'shared/资料（已还原）.txt',
          )));
    });

    test('选中文件夹后会异步统计大小，并复用本次会话缓存', () async {
      final oss = _FakeOssClient()..directorySizes['shared/资料/'] = 3072;
      final controller = await _controller(oss: oss);
      const folder = FileItem(
        path: 'shared/资料/',
        name: '资料',
        isDirectory: true,
      );

      controller.selectItem(folder);
      await Future<void>.delayed(Duration.zero);

      expect(
        controller.directorySizeStatesListenable.value[folder.path]?.size,
        3072,
      );
      expect(oss.directorySizeCalls, 1);

      controller.selectItem(null);
      controller.selectItem(folder);
      await Future<void>.delayed(Duration.zero);
      expect(oss.directorySizeCalls, 1);
    });

    test('删除非空文件夹会递归删除子文件与子目录', () async {
      final oss = _FakeOssClient()
        ..itemsByPath['shared/'] = const <FileItem>[
          FileItem(path: 'shared/目录/', name: '目录', isDirectory: true),
        ]
        ..itemsByPath['shared/目录/'] = const <FileItem>[
          FileItem(path: 'shared/目录/a.txt', name: 'a.txt', isDirectory: false),
          FileItem(path: 'shared/目录/子目录/', name: '子目录', isDirectory: true),
        ]
        ..itemsByPath['shared/目录/子目录/'] = const <FileItem>[
          FileItem(
            path: 'shared/目录/子目录/b.txt',
            name: 'b.txt',
            isDirectory: false,
          ),
        ]
        ..objectKeysByPath['shared/目录/'] = <String>[
          'shared/目录/a.txt',
          'shared/目录/子目录/b.txt',
          'shared/目录/子目录/',
        ];
      final controller = await _controller(oss: oss);
      await controller.listDirectory();
      controller.setCurrentPath('shared/目录/');
      await controller.listDirectory();

      await controller.deleteItem(
        const FileItem(path: 'shared/目录/', name: '目录', isDirectory: true),
      );

      expect(oss.deleted, <String>[
        'shared/目录/',
        'shared/目录/a.txt',
        'shared/目录/子目录/b.txt',
        'shared/目录/子目录/',
      ]);
      expect(oss.copies, hasLength(4));
      expect(controller.sidebarDirectories, isEmpty);
      expect(controller.currentPath, 'shared/');
    });

    test('上传与下载使用正确路径，并阻止文件夹下载', () async {
      final oss = _FakeOssClient()..downloadResult = <int>[1, 2, 3];
      final controller = await _controller(oss: oss);

      final source = File('${Directory.systemTemp.path}/pdd-upload-source.txt');
      await source.writeAsBytes(<int>[7]);
      await controller.uploadFile(
        fileName: '中文 文件.txt',
        localPath: source.path,
        fileSize: 1,
      );
      final bytes = await controller.downloadBytes(
        const FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
      );
      await expectLater(
        controller.downloadBytes(
          const FileItem(path: 'shared/目录/', name: '目录', isDirectory: true),
        ),
        throwsA(isA<StateError>()),
      );

      expect(oss.uploads.single.path, 'shared/中文 文件.txt');
      expect(controller.tasks.single.sourcePath, source.path);
      expect(bytes, <int>[1, 2, 3]);
    });

    test('失败任务可重试，进行中任务可取消', () async {
      final controller = await _controller();
      controller.tasksListenable.value = const <TransferTask>[
        TransferTask(
          id: 'upload-1',
          name: '文件.txt',
          type: TransferTaskType.upload,
          status: TransferTaskStatus.failed,
          progress: 0,
        ),
      ];

      controller.retryTask('upload-1');
      expect(controller.tasks.single.status, TransferTaskStatus.running);
      controller.cancelTask('upload-1');

      expect(controller.tasks.single.status, TransferTaskStatus.canceled);
      expect(controller.tasks.single.message, '已取消');
    });

    test('多选状态支持范围选择、全选与取消', () async {
      final controller = await _controller();
      const items = <FileItem>[
        FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
        FileItem(path: 'shared/b.txt', name: 'b.txt', isDirectory: false),
        FileItem(path: 'shared/c.txt', name: 'c.txt', isDirectory: false),
      ];

      controller.enterMultiSelection(items.first);
      controller.toggleMultiSelection(items.last,
          visibleItems: items, range: true);
      expect(controller.multiSelectedPaths, <String>{
        'shared/a.txt',
        'shared/b.txt',
        'shared/c.txt',
      });

      controller.clearMultiSelection();
      expect(controller.isMultiSelectionMode, isFalse);
      expect(controller.multiSelectedPaths, isEmpty);
    });

    test('键盘方向选择按目录排序移动单个选中项', () async {
      final controller = await _controller();
      const items = <FileItem>[
        FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
        FileItem(path: 'shared/b.txt', name: 'b.txt', isDirectory: false),
        FileItem(path: 'shared/c.txt', name: 'c.txt', isDirectory: false),
      ];

      controller.selectItem(items.first);
      expect(
        controller.moveSelection(items, offset: 1),
        isTrue,
      );
      expect(controller.selectedItem?.path, 'shared/b.txt');
      expect(controller.multiSelectedPaths, isEmpty);

      controller.moveSelection(items, offset: 1);
      expect(controller.selectedItem?.path, 'shared/c.txt');
      expect(controller.multiSelectedPaths, isEmpty);

      controller.moveSelection(items, offset: -1);
      expect(controller.selectedItem?.path, 'shared/b.txt');
      expect(controller.multiSelectedPaths, isEmpty);
    });

    test('批次汇总统计独立下载任务', () async {
      final controller = await _controller();
      controller.tasksListenable.value = const <TransferTask>[
        TransferTask(
          id: 'a',
          name: 'a.txt',
          type: TransferTaskType.download,
          status: TransferTaskStatus.success,
          progress: 1,
          batchId: 'batch-1',
        ),
        TransferTask(
          id: 'b',
          name: 'b.txt',
          type: TransferTaskType.download,
          status: TransferTaskStatus.pending,
          progress: 0,
          batchId: 'batch-1',
        ),
      ];

      final summary = controller.transferBatches.single;
      expect(summary.total, 2);
      expect(summary.success, 1);
      expect(summary.pending, 1);
    });

    test('下载队列遵守动态并发上限', () async {
      final gate = Completer<void>();
      final oss = _FakeOssClient()..downloadGate = gate;
      final controller = await _controller(oss: oss);
      await controller.setTransferConcurrency(1);
      final directory = await Directory.systemTemp.createTemp('pdd-transfer-');
      addTearDown(() => directory.delete(recursive: true));
      const files = <FileItem>[
        FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
        FileItem(path: 'shared/b.txt', name: 'b.txt', isDirectory: false),
      ];

      controller.enqueueDownloads(files, targetDirectory: directory.path);
      await Future<void>.delayed(Duration.zero);
      expect(controller.runningTransferCount, 1);
      expect(controller.pendingTransferCount, 1);

      await controller.setTransferConcurrency(2);
      await Future<void>.delayed(Duration.zero);
      expect(controller.runningTransferCount, 2);
      expect(controller.pendingTransferCount, 0);

      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
          controller.tasks
              .where((task) => task.status == TransferTaskStatus.success),
          hasLength(2));
    });

    test('递归下载保留目录结构并去重重叠选择', () async {
      final oss = _FakeOssClient()
        ..objectKeysByPath['shared/资料/'] = <String>[
          'shared/资料/',
          'shared/资料/a.txt',
          'shared/资料/子目录/b.txt',
        ];
      final controller = await _controller(oss: oss);
      final directory = await Directory.systemTemp.createTemp('pdd-recursive-');
      addTearDown(() => directory.delete(recursive: true));

      final result = await controller.enqueueDownloadsRecursively(
        const <FileItem>[
          FileItem(path: 'shared/资料/', name: '资料', isDirectory: true),
          FileItem(path: 'shared/资料/a.txt', name: 'a.txt', isDirectory: false),
        ],
        targetDirectory: directory.path,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(result.fileCount, 2);
      expect(result.directoryCount, 1);
      expect(controller.tasks.where((task) => task.batchId == result.batchId),
          hasLength(2));
      expect(await File('${directory.path}/资料/a.txt').exists(), isTrue);
      expect(await File('${directory.path}/资料/子目录/b.txt').exists(), isTrue);
    });
    test('同名下载目标自动递增改名并保留扩展名', () async {
      final controller = await _controller();
      final directory = await Directory.systemTemp.createTemp('pdd-rename-');
      addTearDown(() => directory.delete(recursive: true));
      // 占用原名与第一次递增名，应继续递增到 (2)。
      await File('${directory.path}/a.txt').writeAsBytes(<int>[0]);
      await File('${directory.path}/a (1).txt').writeAsBytes(<int>[0]);

      controller.enqueueDownload(
        const FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
        targetDirectory: directory.path,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final task = controller.tasks.single;
      expect(task.status, TransferTaskStatus.success);
      expect(task.target, '${directory.path}/a (2).txt');
      expect(await File('${directory.path}/a (2).txt').exists(), isTrue);
      // 原有文件不被覆盖。
      expect(await File('${directory.path}/a.txt').readAsBytes(), <int>[0]);
    });

    test('无扩展名同名下载目标自动改名', () async {
      final controller = await _controller();
      final directory =
          await Directory.systemTemp.createTemp('pdd-rename-noext-');
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/README').writeAsBytes(<int>[0]);

      controller.enqueueDownload(
        const FileItem(
            path: 'shared/README', name: 'README', isDirectory: false),
        targetDirectory: directory.path,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(controller.tasks.single.status, TransferTaskStatus.success);
      expect(controller.tasks.single.target, '${directory.path}/README (1)');
    });

    test('下载失败时清理 part 临时文件并标记失败', () async {
      final oss = _FakeOssClient()
        ..downloadToFileError = const SocketException('网络中断');
      final controller = await _controller(oss: oss);
      final directory = await Directory.systemTemp.createTemp('pdd-part-fail-');
      addTearDown(() => directory.delete(recursive: true));

      controller.enqueueDownload(
        const FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
        targetDirectory: directory.path,
      );
      await _waitForTaskStatus(
        controller,
        TransferTaskStatus.failed,
      );

      final task = controller.tasks.single;
      expect(task.status, TransferTaskStatus.failed);
      expect(await directory.list().toList(), isEmpty);
    });

    test('下载取消时清理 part 临时文件', () async {
      final gate = Completer<void>();
      final oss = _FakeOssClient()..downloadGate = gate;
      final controller = await _controller(oss: oss);
      final directory =
          await Directory.systemTemp.createTemp('pdd-part-cancel-');
      addTearDown(() => directory.delete(recursive: true));

      controller.enqueueDownload(
        const FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
        targetDirectory: directory.path,
      );
      // 等待任务开始运行并已在临时文件上写入数据。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      controller.cancelTask(controller.tasks.single.id);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final task = controller.tasks.single;
      expect(task.status, TransferTaskStatus.canceled);
      expect(oss.canceledTaskIds, contains(task.id));
      expect(await directory.list().toList(), isEmpty);
    });

    test('字节完成后等待 OSS 确认并使用时间窗口计算速度', () async {
      final gate = Completer<void>();
      final oss = _FakeOssClient()
        ..downloadGate = gate
        ..progressReports = <(int, int)>[(25, 100), (100, 100)]
        ..progressInterval = const Duration(milliseconds: 600);
      final controller = await _controller(oss: oss);
      final directory = await Directory.systemTemp.createTemp('pdd-confirm-');
      addTearDown(() => directory.delete(recursive: true));

      controller.enqueueDownload(
        const FileItem(path: 'shared/a.bin', name: 'a.bin', isDirectory: false),
        targetDirectory: directory.path,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1300));

      final confirming = controller.tasks.single;
      expect(confirming.status, TransferTaskStatus.running);
      expect(confirming.message, '正在确认');
      expect(confirming.progress, 1);
      expect(confirming.bytesPerSecond, greaterThan(0));

      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(controller.tasks.single.status, TransferTaskStatus.success);
    });
  });
}

Future<AppController> _controller({_FakeOssClient? oss}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final controller = AppController(
    sessionRepository: _FakeSessionRepository(_remoteSession()),
    ossClient: oss ?? _FakeOssClient(),
  );
  await controller.bootstrap();
  return controller;
}

Future<void> _waitForTaskStatus(
  AppController controller,
  TransferTaskStatus status,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (controller.tasks.single.status != status) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('传输任务未在限定时间内进入 $status 状态');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

UserSession _remoteSession() {
  return UserSession(
    userId: 'test-user',
    account: 'test',
    displayName: '测试成员',
    role: 'member',
    capabilities: const Capabilities.standard(),
    rootPrefix: 'shared/',
    ossConfig: const OssConfig(
      bucket: 'test-bucket',
      region: 'cn-hangzhou',
      endpoint: 'oss-cn-hangzhou.aliyuncs.com',
      rootPrefix: 'shared/',
    ),
    credentials: StsCredentials(
      accessKeyId: 'id',
      accessKeySecret: 'secret',
      securityToken: 'token',
      expiration: DateTime.now().toUtc().add(const Duration(hours: 1)),
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
  Future<UserSession> refreshCredentials(UserSession session) async => session;

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
  final Map<String, List<FileItem>> itemsByPath = <String, List<FileItem>>{};
  final Map<String, List<String>> objectKeysByPath = <String, List<String>>{};
  final Map<String, int> directorySizes = <String, int>{};
  final Set<String> existingPaths = <String>{};
  int directorySizeCalls = 0;
  final List<String> createdFolders = <String>[];
  final List<String> deleted = <String>[];
  final List<(String, String)> copies = <(String, String)>[];
  final List<({String path, String localPath})> uploads =
      <({String path, String localPath})>[];
  List<int> downloadResult = const <int>[];
  Completer<void>? downloadGate;
  Object? downloadToFileError;
  List<(int, int)> progressReports = <(int, int)>[];
  Duration progressInterval = Duration.zero;
  final List<String> canceledTaskIds = <String>[];

  @override
  Future<List<FileItem>> list(String path, UserSession session) async =>
      itemsByPath[path] ?? const <FileItem>[];

  @override
  Future<List<String>> listAllObjectKeys(
          String path, UserSession session) async =>
      objectKeysByPath[path] ?? const <String>[];

  @override
  Future<int> calculateDirectorySize(String path, UserSession session) async {
    directorySizeCalls++;
    return directorySizes[path] ?? 0;
  }

  @override
  Future<void> createFolder(String path, UserSession session) async {
    createdFolders.add(path);
  }

  @override
  Future<void> copy(String from, String to, UserSession session) async {
    copies.add((from, to));
  }

  @override
  Future<bool> objectExists(String path, UserSession session) async =>
      existingPaths.contains(path);

  @override
  Future<void> delete(String path, UserSession session) async {
    deleted.add(path);
  }

  @override
  Future<BatchDeleteResult> deleteMany(
    Iterable<String> paths,
    UserSession session,
  ) async {
    final values = paths.toList(growable: false);
    deleted.addAll(values);
    return BatchDeleteResult(deletedPaths: values);
  }

  @override
  Future<void> uploadFile(
    String path,
    String localPath,
    UserSession session, {
    required String taskId,
    void Function(int transferredBytes, int totalBytes)? onProgress,
  }) async {
    uploads.add((path: path, localPath: localPath));
    final size = await File(localPath).length();
    onProgress?.call(size, size);
  }

  @override
  Future<List<int>> download(String path, UserSession session) async =>
      downloadResult;

  @override
  Future<void> downloadToFile(
    String path,
    UserSession session,
    File target, {
    required String taskId,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {
    // 先落盘再等待闸门，模拟流式写入中途被取消/失败的场景。
    await target.parent.create(recursive: true);
    await target.writeAsBytes(<int>[1], flush: true);
    for (final report in progressReports) {
      onProgress(report.$1, report.$2);
      if (progressInterval > Duration.zero) {
        await Future<void>.delayed(progressInterval);
      }
    }
    final gate = downloadGate;
    if (gate != null) await gate.future;
    if (isCanceled()) throw const TransferCanceledException();
    onProgress(1, 1);
    final error = downloadToFileError;
    if (error != null) throw error;
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
