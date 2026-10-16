import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/application/session_controller.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/workspace/application/recycle_bin_controller.dart';
import 'package:private_domain_drive_client/features/workspace/application/workspace_controller.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/domain/recycle_bin_entry.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('RecycleBinController', () {
    test('删除选中项后会清空选中状态', () async {
      final oss = _FakeOssClient();
      final stack = await _recycleBinStack(oss: oss);
      addTearDown(stack.dispose);
      const item =
          FileItem(path: 'shared/删除我.txt', name: '删除我.txt', isDirectory: false);
      stack.workspace.selectItem(item);

      await stack.controller.deleteItem(item);

      expect(oss.deleted, <String>['shared/删除我.txt']);
      expect(stack.workspace.selectedItem, isNull);
    });

    test('恢复时同名路径会使用已还原名称且不覆盖现有对象', () async {
      final oss = _FakeOssClient()..existingPaths.add('shared/资料.txt');
      final stack = await _recycleBinStack(oss: oss);
      addTearDown(stack.dispose);
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

      await stack.controller.restoreRecycleBinEntry(entry);

      expect(
          oss.copies,
          contains((
            'shared/.trash/batch-1/payload/资料.txt',
            'shared/资料（已还原）.txt',
          )));
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
      final stack = await _recycleBinStack(oss: oss);
      addTearDown(stack.dispose);
      await stack.workspace.listDirectory();
      stack.workspace.setCurrentPath('shared/目录/');
      await stack.workspace.listDirectory();

      await stack.controller.deleteItem(
        const FileItem(path: 'shared/目录/', name: '目录', isDirectory: true),
      );

      expect(oss.deleted, <String>[
        'shared/目录/',
        'shared/目录/a.txt',
        'shared/目录/子目录/b.txt',
        'shared/目录/子目录/',
      ]);
      expect(oss.copies, hasLength(4));
      expect(stack.workspace.sidebarDirectories, isEmpty);
      expect(stack.workspace.currentPath, 'shared/');
    });
  });
}

typedef _RecycleBinStack = ({
  RecycleBinController controller,
  WorkspaceController workspace,
  _FakeOssClient oss,
  void Function() dispose,
});

/// 直测夹层：按生产装配顺序构建 Session → Workspace → RecycleBinController，
/// 不经过 AppServices 门面。
Future<_RecycleBinStack> _recycleBinStack({_FakeOssClient? oss}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final client = oss ?? _FakeOssClient();
  final sessionController = SessionController(
    sessionRepository: _FakeSessionRepository(_session()),
    ossClient: client,
  );
  await sessionController.bootstrap();
  final workspaceController = WorkspaceController(
    sessionController: sessionController,
    ossClient: client,
  );
  final controller = RecycleBinController(
    sessionController: sessionController,
    workspaceController: workspaceController,
    ossClient: client,
  );

  void dispose() {
    controller.dispose();
    workspaceController.dispose();
    sessionController.dispose();
  }

  return (
    controller: controller,
    workspace: workspaceController,
    oss: client,
    dispose: dispose,
  );
}

UserSession _session() {
  return const UserSession(
    userId: 'test-user',
    account: 'test',
    displayName: '测试成员',
    role: 'member',
    capabilities: Capabilities.standard(),
    rootPrefix: 'shared/',
    ossConfig: OssConfig(
      bucket: 'test-bucket',
      region: 'cn-hangzhou',
      endpoint: 'oss-cn-hangzhou.aliyuncs.com',
      rootPrefix: 'shared/',
    ),
    credentials: OssCredentials(
      accessKeyId: 'id',
      accessKeySecret: 'secret',
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
    // 不读取真实文件，保证 testWidgets 的 FakeAsync 环境下可完成。
    onProgress?.call(1, 1);
  }

  @override
  Future<List<int>> download(
    String path,
    UserSession session, {
    int? maxBytes,
  }) async =>
      downloadResult;

  @override
  Future<List<String>> listPrefixes(
    String prefix,
    UserSession session,
  ) async =>
      const <String>[];

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
