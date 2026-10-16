import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/application/session_controller.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/workspace/application/workspace_controller.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/shared/path_utils.dart' as path_utils;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('WorkspaceController', () {
    test('启动后恢复缩略图尺寸，并保存新的选择', () async {
      final stack = await _workspaceStack(
        preferences: <String, Object>{'thumbnail_size': 'large'},
      );
      addTearDown(stack.dispose);
      final controller = stack.controller;
      controller.restorePreferences(await SharedPreferences.getInstance());

      expect(controller.thumbnailSize, ThumbnailSize.large);

      await controller.setThumbnailSize(ThumbnailSize.small);
      expect(
        (await SharedPreferences.getInstance()).getString('thumbnail_size'),
        'small',
      );
    });

    test('无效缩略图尺寸偏好会使用中档', () async {
      final stack = await _workspaceStack(
        preferences: <String, Object>{'thumbnail_size': 'extra-large'},
      );
      addTearDown(stack.dispose);
      final controller = stack.controller;
      controller.restorePreferences(await SharedPreferences.getInstance());

      expect(controller.thumbnailSize, ThumbnailSize.medium);
    });

    test('目录浏览会记录目录树并支持返回上级', () async {
      final oss = _FakeOssClient()
        ..itemsByPath['shared/'] = const <FileItem>[
          FileItem(path: 'shared/相册/', name: '相册', isDirectory: true),
        ];
      final stack = await _workspaceStack(oss: oss);
      addTearDown(stack.dispose);
      final controller = stack.controller;

      final items = await controller.listDirectory();
      controller.setCurrentPath('shared/相册');

      expect(items.single.name, '相册');
      expect(controller.sidebarDirectories, <String>['shared/相册/']);
      expect(path_utils.parentPathOf(controller.currentPath), 'shared/');
    });

    test('首次加载根目录会通知侧栏刷新', () async {
      final oss = _FakeOssClient()
        ..itemsByPath['shared/'] = const <FileItem>[
          FileItem(path: 'shared/相册/', name: '相册', isDirectory: true),
        ];
      final stack = await _workspaceStack(oss: oss);
      addTearDown(stack.dispose);
      final controller = stack.controller;
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.listDirectory();

      expect(notifications, 1);
      expect(controller.sidebarDirectories, <String>['shared/相册/']);
    });

    test('新建文件夹会校验空名称并使用当前目录', () async {
      final oss = _FakeOssClient();
      final stack = await _workspaceStack(oss: oss);
      addTearDown(stack.dispose);
      final controller = stack.controller;

      await expectLater(controller.createFolder('  '), throwsA(isA<StateError>()));
      await controller.createFolder('资料');

      expect(oss.createdFolders, <String>['shared/资料/']);
      expect(controller.treeRevision, 1);
    });

    test('重命名通过复制后删除完成，并刷新树版本', () async {
      final oss = _FakeOssClient();
      final stack = await _workspaceStack(oss: oss);
      addTearDown(stack.dispose);
      final controller = stack.controller;
      const item =
          FileItem(path: 'shared/旧名.txt', name: '旧名.txt', isDirectory: false);

      await controller.renameItem(item, '新名.txt');

      expect(
          oss.copies, <(String, String)>[('shared/旧名.txt', 'shared/新名.txt')]);
      expect(oss.deleted, <String>['shared/旧名.txt']);
      expect(controller.treeRevision, 1);
    });

    test('选中文件夹后会异步统计大小，并复用本次会话缓存', () async {
      final oss = _FakeOssClient()..directorySizes['shared/资料/'] = 3072;
      final stack = await _workspaceStack(oss: oss);
      addTearDown(stack.dispose);
      final controller = stack.controller;
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

    test('多选状态支持范围选择、全选与取消', () async {
      final stack = await _workspaceStack();
      addTearDown(stack.dispose);
      final controller = stack.controller;
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
      final stack = await _workspaceStack();
      addTearDown(stack.dispose);
      final controller = stack.controller;
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
  });
}

typedef _WorkspaceStack = ({
  WorkspaceController controller,
  _FakeOssClient oss,
  void Function() dispose,
});

/// 直测夹层：按生产装配顺序构建 SessionController → WorkspaceController，
/// 不经过 AppServices 聚合层。
Future<_WorkspaceStack> _workspaceStack({
  _FakeOssClient? oss,
  Map<String, Object> preferences = const <String, Object>{},
}) async {
  SharedPreferences.setMockInitialValues(preferences);
  final client = oss ?? _FakeOssClient();
  final sessionController = SessionController(
    sessionRepository: _FakeSessionRepository(_remoteSession()),
    ossClient: client,
  );
  await sessionController.bootstrap();
  final controller = WorkspaceController(
    sessionController: sessionController,
    ossClient: client,
  );

  void dispose() {
    controller.dispose();
    sessionController.dispose();
  }

  return (controller: controller, oss: client, dispose: dispose);
}

UserSession _remoteSession() {
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
  Future<List<int>> download(
    String path,
    UserSession session, {
    int? maxBytes,
  }) async =>
      const <int>[];

  @override
  Future<List<String>> listPrefixes(
    String prefix,
    UserSession session,
  ) async =>
      const <String>[];

  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<void> clearConfiguration() async {}

  @override
  Future<void> cancelTransfer(String taskId) async {}
}
