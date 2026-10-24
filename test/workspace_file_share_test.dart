import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/file_share/application/file_share_controller.dart';
import 'package:private_domain_drive_client/features/file_share/infrastructure/share_cache_store.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/features/workspace/presentation/workspace_page.dart';
import 'package:private_domain_drive_client/shared/state/app_scope.dart';
import 'package:private_domain_drive_client/shared/state/app_services.dart';
import 'package:private_domain_oss/private_domain_oss.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  final files = <FileItem>[
    const FileItem(
      path: 'shared/a.txt',
      name: 'a.txt',
      isDirectory: false,
      size: 4,
    ),
    const FileItem(
      path: 'shared/b.txt',
      name: 'b.txt',
      isDirectory: false,
      size: 4,
    ),
  ];

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android 单文件选中时展示分享入口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _pumpWorkspace(tester, files);

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();

    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('多选文件时展示分享入口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _pumpWorkspace(tester, files);

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('b.txt'));
    await tester.pumpAndSettle();

    expect(find.text('已选 2 项'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('选择包含文件夹时不展示分享入口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const folder = FileItem(
      path: 'shared/资料/',
      name: '资料',
      isDirectory: true,
    );
    await _pumpWorkspace(tester, <FileItem>[files.first, folder]);

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('资料'));
    await tester.pumpAndSettle();

    expect(find.text('已选 2 项'), findsOneWidget);
    expect(find.text('分享'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('文件夹与别名不展示分享入口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const folder = FileItem(
      path: 'shared/资料/',
      name: '资料',
      isDirectory: true,
    );
    const alias = FileItem(
      path: 'shared/target/',
      name: '链接',
      isDirectory: false,
      isAlias: true,
    );
    final services = await _pumpWorkspace(tester, <FileItem>[folder, alias]);

    await tester.longPress(find.text('资料'));
    await tester.pumpAndSettle();
    expect(find.text('分享'), findsNothing);

    services.workspaceController.clearMultiSelection();
    services.workspaceController.enterMultiSelection(alias);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.text('分享'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('无下载能力时不展示分享入口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _pumpWorkspace(
      tester,
      files,
      session: _session(
        capabilities: const Capabilities(
          list: true,
          download: false,
          upload: true,
          delete: true,
          preview: true,
        ),
      ),
    );

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();

    expect(find.text('分享'), findsNothing);
    expect(find.text('下载'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('macOS 不展示分享入口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await _pumpWorkspace(tester, files);

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();

    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.text('分享'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android 文件更多菜单展示分享入口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _pumpWorkspace(tester, files);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();

    expect(find.text('分享'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('macOS 文件更多菜单不展示分享入口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await _pumpWorkspace(tester, files);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();

    expect(find.text('分享'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('多选文件分享时一次传入全部本地路径', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final completer = Completer<ShareResult>();
    List<String>? sharedPaths;
    await _pumpWorkspace(
      tester,
      files,
      shareFilesInvoker: (paths) {
        sharedPaths = paths;
        return completer.future;
      },
    );

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('b.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分享'));
    await tester.pumpAndSettle();

    expect(sharedPaths, hasLength(2));
    completer.complete(const ShareResult('', ShareResultStatus.success));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('重复点击分享只执行一次，分享后选择状态不变', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final completer = Completer<ShareResult>();
    var invocations = 0;
    final services = await _pumpWorkspace(
      tester,
      files,
      shareFilesInvoker: (paths) {
        invocations++;
        return completer.future;
      },
    );

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('分享'));
    await tester.pumpAndSettle();
    expect(invocations, 1);

    // 系统分享面板尚未返回时再次点击应被忽略。
    await tester.tap(find.text('分享'));
    await tester.pump();

    completer.complete(const ShareResult('', ShareResultStatus.success));
    await tester.pumpAndSettle();

    expect(invocations, 1);
    expect(
      services.workspaceController.multiSelectedPaths,
      contains('shared/a.txt'),
    );
    debugDefaultTargetPlatformOverride = null;
  });
}

Future<AppServices> _pumpWorkspace(
  WidgetTester tester,
  List<FileItem> items, {
  UserSession? session,
  ShareFilesInvoker? shareFilesInvoker,
}) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final services = AppServices(
    sessionRepository: _FakeSessionRepository(session ?? _session()),
    ossClient: _FakeOssClient(items),
    shareCacheStore: _MemoryShareCacheStore(),
    shareFilesInvoker: shareFilesInvoker,
  );
  await services.bootstrap();
  await tester.pumpWidget(
    AppScope(
      services: services,
      child: const MaterialApp(
        home: WorkspacePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return services;
}

UserSession _session({Capabilities? capabilities}) {
  return UserSession(
    userId: 'test-user',
    account: 'test',
    displayName: '测试成员',
    role: 'member',
    capabilities: capabilities ?? const Capabilities.standard(),
    rootPrefix: 'shared/',
    ossConfig: const OssConfig(
      bucket: 'test-bucket',
      region: 'cn-hangzhou',
      endpoint: 'oss-cn-hangzhou.aliyuncs.com',
      rootPrefix: 'shared/',
    ),
    credentials: const OssCredentials(
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
  Future<UserSession> login({
    required String account,
    required String password,
  }) async =>
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
  _FakeOssClient(this.items);

  final List<FileItem> items;

  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<void> clearConfiguration() async {}

  @override
  Future<void> copy(String from, String to, UserSession session) async {}

  @override
  Future<void> uploadText(
    String path,
    String content,
    UserSession session,
  ) async {}

  @override
  Future<List<FileItem>> list(String path, UserSession session) async => items;

  @override
  Future<List<String>> listPrefixes(
    String prefix,
    UserSession session,
  ) async =>
      const <String>[];

  @override
  Future<List<String>> listAllObjectKeys(
    String path,
    UserSession session,
  ) async =>
      const <String>[];

  @override
  Future<List<OssNativeObject>> listAllObjects(
    String path,
    UserSession session,
  ) async =>
      const <OssNativeObject>[];

  @override
  Future<BatchDeleteResult> deleteMany(
    Iterable<String> paths,
    UserSession session,
  ) async =>
      const BatchDeleteResult();

  @override
  Future<void> downloadToFile(
    String path,
    UserSession session,
    File target, {
    required String taskId,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {
    onProgress(4, 4);
  }

  @override
  Future<void> cancelTransfer(String taskId) async {}
}

/// 内存缓存实现：widget 测试的 FakeAsync 区域无法推进真实文件 IO，
/// 因此只模拟路径与命中逻辑。
class _MemoryShareCacheStore extends ShareCacheStore {
  @override
  Future<File> fileFor(FileItem item) async =>
      File('/virtual/${ShareCacheStore.cacheDirectoryName(item)}/'
          '${ShareCacheStore.sanitizeFileName(item.name)}');

  @override
  Future<File?> lookup(FileItem item) async => null;

  @override
  Future<File> temporaryFileFor(File target) async => File('${target.path}.part');

  @override
  Future<File> commit(File temporary, File target) async => target;

  @override
  Future<void> discard(File temporary) async {}

  @override
  Future<int> clean({
    Set<String> keepPaths = const <String>{},
    DateTime? now,
  }) async =>
      0;
}
