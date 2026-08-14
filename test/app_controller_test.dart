import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/transfer/domain/transfer_task.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
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
        ];
      final controller = await _controller(oss: oss);
      await controller.listDirectory();
      controller.setCurrentPath('shared/目录/');
      await controller.listDirectory();

      await controller.deleteItem(
        const FileItem(path: 'shared/目录/', name: '目录', isDirectory: true),
      );

      expect(oss.deleted, <String>[
        'shared/目录/a.txt',
        'shared/目录/子目录/b.txt',
        'shared/目录/子目录/',
        'shared/目录/',
      ]);
      expect(controller.sidebarDirectories, isEmpty);
      expect(controller.currentPath, 'shared/');
    });

    test('上传与下载使用正确路径，并阻止文件夹下载', () async {
      final oss = _FakeOssClient()..downloadResult = <int>[1, 2, 3];
      final controller = await _controller(oss: oss);

      await controller.uploadBytes(fileName: '中文 文件.txt', bytes: <int>[7]);
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
  });
}

Future<AppController> _controller({_FakeOssClient? oss}) async {
  final controller = AppController(
    sessionRepository: _FakeSessionRepository(_remoteSession()),
    ossClient: oss ?? _FakeOssClient(),
  );
  await controller.bootstrap();
  return controller;
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
  Future<UserSession?> restore() async => session;
}

class _FakeOssClient extends OssClient {
  final Map<String, List<FileItem>> itemsByPath = <String, List<FileItem>>{};
  final List<String> createdFolders = <String>[];
  final List<String> deleted = <String>[];
  final List<(String, String)> copies = <(String, String)>[];
  final List<({String path, List<int> bytes})> uploads =
      <({String path, List<int> bytes})>[];
  List<int> downloadResult = const <int>[];

  @override
  Future<List<FileItem>> list(String path, UserSession session) async =>
      itemsByPath[path] ?? const <FileItem>[];

  @override
  Future<void> createFolder(String path, UserSession session) async {
    createdFolders.add(path);
  }

  @override
  Future<void> copy(String from, String to, UserSession session) async {
    copies.add((from, to));
  }

  @override
  Future<void> delete(String path, UserSession session) async {
    deleted.add(path);
  }

  @override
  Future<void> upload(String path, List<int> bytes, UserSession session) async {
    uploads.add((path: path, bytes: bytes));
  }

  @override
  Future<List<int>> download(String path, UserSession session) async =>
      downloadResult;
}
