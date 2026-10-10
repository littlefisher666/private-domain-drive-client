import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/workspace/domain/directory_alias.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';
import 'package:private_domain_oss/private_domain_oss.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// 仅覆盖别名链路涉及的 OssClient 方法；其余方法不应被别名逻辑触达。
class _AliasFakeOssClient extends OssClient {
  final Map<String, List<FileItem>> itemsByPath = <String, List<FileItem>>{};
  final Map<String, Set<String>> entryNamesByPrefix =
      <String, Set<String>>{};
  DirectoryAliasTable table = const DirectoryAliasTable();
  String etag = 'etag-1';

  String get tableKey => 'shared/.aliases/links.json';

  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<List<FileItem>> list(String path, UserSession session) async =>
      itemsByPath[path] ?? const <FileItem>[];

  @override
  Future<List<OssNativeObject>> listAllObjects(
    String path,
    UserSession session,
  ) async {
    if (path != tableKey) return const <OssNativeObject>[];
    return <OssNativeObject>[
      OssNativeObject(key: path, size: 1, etag: etag),
    ];
  }

  @override
  Future<List<int>> download(
    String path,
    UserSession session, {
    int? maxBytes,
  }) async {
    if (path != tableKey) return const <int>[];
    return utf8.encode(table.encode());
  }

  @override
  Future<void> uploadText(
    String path,
    String content,
    UserSession session,
  ) async {
    if (path != tableKey) return;
    table = DirectoryAliasTable.decode(content, defaultParentPrefix: 'shared/');
    etag = 'etag-${table.aliases.length}';
  }

  @override
  Future<DirectorySummary> directorySummary(
    String path,
    UserSession session,
  ) async =>
      const DirectorySummary(itemCount: 2, updatedAt: null);

  @override
  Future<bool> directoryExists(String path, UserSession session) async =>
      itemsByPath.containsKey(path) || path.startsWith('shared/');

  @override
  Future<Set<String>> listEntryNames(
    String prefix,
    UserSession session,
  ) async =>
      entryNamesByPrefix[prefix] ?? const <String>{};
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

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<AppController> login(_AliasFakeOssClient oss) async {
    final controller = AppController(
      sessionRepository: _FakeSessionRepository(_session()),
      ossClient: oss,
    );
    await controller.bootstrap();
    await controller.login(account: 'test', password: '123456');
    return controller;
  }

  DirectoryAlias alias(
    String name,
    String target, {
    String parent = 'shared/家庭资料/',
  }) {
    return DirectoryAlias.create(
      name: name,
      targetPrefix: target,
      parentPrefix: parent,
      createdBy: '测试成员',
    );
  }

  test('同层别名指向同层真实目录时与真实条目并列展示', () async {
    final oss = _AliasFakeOssClient()
      ..itemsByPath['shared/家庭资料/'] = const <FileItem>[
        FileItem(
          path: 'shared/家庭资料/医疗/',
          name: '医疗',
          isDirectory: true,
        ),
      ]
      ..table = DirectoryAliasTable(aliases: <DirectoryAlias>[
        alias('医疗1', 'shared/家庭资料/医疗/'),
      ]);
    final controller = await login(oss);

    final items = await controller.listDirectory('shared/家庭资料/');

    expect(
      items.where((item) => item.name == '医疗'),
      hasLength(1),
    );
    final aliasItem = items.singleWhere((item) => item.name == '医疗1');
    expect(aliasItem.isAlias, isTrue);
    expect(aliasItem.path, 'shared/家庭资料/医疗/');
    expect(aliasItem.itemCount, 2);
  });

  test('别名名称与挂载层级真实条目重名时拒绝创建', () async {
    final oss = _AliasFakeOssClient()
      ..entryNamesByPrefix['shared/家庭资料/'] = <String>{'医疗'};
    final controller = await login(oss);

    await expectLater(
      controller.createAlias(
        const FileItem(
          path: 'shared/家庭资料/医疗/',
          name: '医疗',
          isDirectory: true,
        ),
        '医疗',
        parentPrefix: 'shared/家庭资料/',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('别名条目不参与多选，避免与真实条目共用路径产生误操作', () async {
    final oss = _AliasFakeOssClient()
      ..table = DirectoryAliasTable(aliases: <DirectoryAlias>[
        alias('医疗1', 'shared/家庭资料/医疗/'),
      ]);
    final controller = await login(oss);

    final items = await controller.listDirectory('shared/家庭资料/');
    final aliasItem = items.singleWhere((item) => item.name == '医疗1');
    controller.toggleMultiSelection(aliasItem);

    expect(controller.isMultiSelectionMode, isFalse);
    expect(controller.multiSelectedPaths, isEmpty);
  });
}
