import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/features/workspace/presentation/workspace_page.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';
import 'package:private_domain_drive_client/shared/state/app_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // bootstrap() 会读取 SharedPreferences；widget 测试的 FakeAsync 环境
  // 必须注入 mock，否则平台通道 Future 永远不会完成。
  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  final items = <FileItem>[
    const FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
    const FileItem(path: 'shared/b.txt', name: 'b.txt', isDirectory: false),
    const FileItem(path: 'shared/c.txt', name: 'c.txt', isDirectory: false),
  ];

  testWidgets('桌面列表支持多选、复选框切换、范围选择与退出', (tester) async {
    final controller = await _pumpWorkspace(tester, items);

    // 未进入多选时不显示复选框。
    expect(find.byType(Checkbox), findsNothing);

    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    expect(controller.isMultiSelectionMode, isTrue);
    expect(find.text('已选 0 项'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(3));

    // 点击行切换选中。
    await tester.tap(find.text('b.txt'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(controller.multiSelectedPaths, <String>{'shared/b.txt'});

    // Shift + 点击做范围选择。
    await tester.tap(find.text('a.txt'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('c.txt'));
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(controller.multiSelectedPaths, <String>{
      'shared/a.txt',
      'shared/b.txt',
      'shared/c.txt',
    });
    expect(find.text('已选 3 项'), findsOneWidget);

    // 退出选择后恢复普通浏览。
    await tester.tap(find.text('退出选择'));
    await tester.pumpAndSettle();
    expect(controller.isMultiSelectionMode, isFalse);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('桌面支持 Cmd+A 全选与全选按钮', (tester) async {
    final controller = await _pumpWorkspace(tester, items);

    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();

    // Cmd+A 触发全选。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.multiSelectedPaths.length, 3);
    expect(find.text('已选 3 项'), findsOneWidget);

    // 工具栏全选按钮在已全选时变为重新全选。
    expect(find.text('重新全选'), findsOneWidget);
  });

  testWidgets('移动端长按列表可进入多选并支持点击切换', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = await _pumpWorkspace(tester, items, desktop: false);

    // 长按列表项进入多选，并选中该项。
    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();
    expect(controller.isMultiSelectionMode, isTrue);
    expect(controller.multiSelectedPaths, <String>{'shared/a.txt'});

    // 多选模式下点击切换选中。
    await tester.tap(find.text('b.txt'));
    await tester.pumpAndSettle();
    expect(controller.multiSelectedPaths,
        <String>{'shared/a.txt', 'shared/b.txt'});

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 项'), findsOneWidget);

    await tester.tap(find.text('退出选择'));
    await tester.pumpAndSettle();
    expect(controller.isMultiSelectionMode, isFalse);
  });

  testWidgets('批量下载展开文件夹入队并提示保留结构', (tester) async {
    final directory = await Directory.systemTemp.createTemp('pdd-batch-ui-');
    addTearDown(() => directory.delete(recursive: true));
    final originalPicker = FilePicker.platform;
    addTearDown(() => FilePicker.platform = originalPicker);
    FilePicker.platform = _FakeFilePicker(directory.path);

    final oss = _FakeOssClient()
      ..itemsByPath['shared/'] = <FileItem>[
        const FileItem(path: 'shared/资料/', name: '资料', isDirectory: true),
        const FileItem(path: 'shared/c.txt', name: 'c.txt', isDirectory: false),
      ]
      ..objectKeysByPath['shared/资料/'] = <String>[
        'shared/资料/',
        'shared/资料/a.txt',
        'shared/资料/子目录/b.txt',
      ];
    final controller = await _pumpWorkspace(tester,
        <FileItem>[oss.itemsByPath['shared/']!.first, items.first],
        oss: oss);

    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();

    // 提示已展开文件夹并保留结构，且多选状态被清理。
    expect(find.text('已加入 3 个下载任务，已保留文件夹结构'), findsOneWidget);
    expect(controller.isMultiSelectionMode, isFalse);
    final batchTasks = controller.tasks
        .where((task) => task.batchId != null)
        .toList(growable: false);
    expect(batchTasks, hasLength(3));
    expect(controller.transferBatches.single.total, 3);
    expect(await File('${directory.path}/资料/a.txt').exists(), isTrue);
    expect(await File('${directory.path}/资料/子目录/b.txt').exists(), isTrue);
    expect(await File('${directory.path}/c.txt').exists(), isTrue);
  });

  testWidgets('批量下载空文件夹时提示没有可下载文件', (tester) async {
    final directory = await Directory.systemTemp.createTemp('pdd-empty-ui-');
    addTearDown(() => directory.delete(recursive: true));
    final originalPicker = FilePicker.platform;
    addTearDown(() => FilePicker.platform = originalPicker);
    FilePicker.platform = _FakeFilePicker(directory.path);

    final oss = _FakeOssClient()
      ..itemsByPath['shared/'] = <FileItem>[
        const FileItem(path: 'shared/空文件夹/', name: '空文件夹', isDirectory: true),
      ]
      ..objectKeysByPath['shared/空文件夹/'] = <String>['shared/空文件夹/'];
    final controller =
        await _pumpWorkspace(tester, oss.itemsByPath['shared/']!, oss: oss);

    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();

    expect(find.text('所选文件夹为空，没有可下载文件'), findsOneWidget);
    expect(controller.tasks.where((task) => task.batchId != null), isEmpty);
  });

  testWidgets('批量删除前展示不可恢复确认并展示对象数，取消则不删除', (tester) async {
    final oss = _FakeOssClient()
      ..itemsByPath['shared/'] = <FileItem>[
        const FileItem(path: 'shared/资料/', name: '资料', isDirectory: true),
        const FileItem(path: 'shared/b.txt', name: 'b.txt', isDirectory: false),
      ]
      ..objectKeysByPath['shared/资料/'] = <String>[
        'shared/资料/',
        'shared/资料/a.txt',
      ];
    await _pumpWorkspace(
        tester, <FileItem>[oss.itemsByPath['shared/']!.first, items.first],
        oss: oss);

    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('确认删除 2 项？')),
        findsOneWidget);
    expect(
      find.descendant(
        of: dialog,
        matching: find.textContaining('其中包含 1 个文件夹，共影响 3 个对象'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('删除后无法恢复')),
      findsOneWidget,
    );

    await tester.tap(find.descendant(of: dialog, matching: find.text('取消')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(oss.deleteManyCalls, 0);
  });

  testWidgets('批量删除部分失败时反馈失败项并支持重试', (tester) async {
    final oss = _FakeOssClient()
      ..itemsByPath['shared/'] = <FileItem>[
        const FileItem(path: 'shared/资料/', name: '资料', isDirectory: true),
        const FileItem(path: 'shared/b.txt', name: 'b.txt', isDirectory: false),
      ]
      ..objectKeysByPath['shared/资料/'] = <String>[
        'shared/资料/',
        'shared/资料/a.txt',
      ]
      ..firstDeleteFailures = <String>{'shared/b.txt'};
    final controller = await _pumpWorkspace(
        tester, <FileItem>[oss.itemsByPath['shared/']!.first, items.first],
        oss: oss);

    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    final confirmDialog = find.byType(AlertDialog);
    await tester
        .tap(find.descendant(of: confirmDialog, matching: find.text('删除')));
    await tester.pumpAndSettle();

    // 首次删除 2 项成功、1 项失败，展示部分失败反馈。
    final retryDialog = find.byType(AlertDialog);
    expect(retryDialog, findsOneWidget);
    expect(
      find.descendant(
          of: retryDialog, matching: find.text('部分删除失败')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: retryDialog, matching: find.textContaining('已删除 2 项，1 项失败')),
      findsOneWidget,
    );

    await tester.tap(
        find.descendant(of: retryDialog, matching: find.text('重试失败项')));
    await tester.pumpAndSettle();

    expect(oss.deleteManyCalls, 2);
    expect(find.text('已删除 3 项'), findsOneWidget);
    expect(controller.isMultiSelectionMode, isFalse);
  });
}

Future<AppController> _pumpWorkspace(
  WidgetTester tester,
  List<FileItem> files, {
  bool desktop = true,
  _FakeOssClient? oss,
}) async {
  final controller = AppController(
    sessionRepository: _FakeSessionRepository(_session()),
    ossClient: oss ?? _FakeOssClient()..itemsByPath['shared/'] = files,
  );
  await controller.bootstrap();
  await tester.pumpWidget(
    AppScope(
      controller: controller,
      child: MaterialApp(
        home: WorkspacePage(desktopChrome: desktop),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

UserSession _session() {
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

class _FakeFilePicker implements FilePicker {
  _FakeFilePicker(this.directoryPath);

  final String? directoryPath;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async =>
      directoryPath;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeOssClient extends OssClient {
  final Map<String, List<FileItem>> itemsByPath = <String, List<FileItem>>{};
  final Map<String, List<String>> objectKeysByPath = <String, List<String>>{};
  int deleteManyCalls = 0;
  Set<String> firstDeleteFailures = <String>{};

  @override
  Future<List<FileItem>> list(String path, UserSession session) async =>
      itemsByPath[path] ?? const <FileItem>[];

  @override
  Future<List<String>> listAllObjectKeys(String path, UserSession session) =>
      Future<void>.value().then(
          (_) => objectKeysByPath[path] ?? const <String>[]);

  @override
  Future<BatchDeleteResult> deleteMany(
    Iterable<String> paths,
    UserSession session,
  ) async {
    deleteManyCalls++;
    final requested = paths.toList(growable: false);
    if (deleteManyCalls == 1 && firstDeleteFailures.isNotEmpty) {
      return BatchDeleteResult(
        deletedPaths: requested
            .where((path) => !firstDeleteFailures.contains(path))
            .toList(growable: false),
        failedPaths: requested
            .where((path) => firstDeleteFailures.contains(path))
            .toList(growable: false),
      );
    }
    return BatchDeleteResult(deletedPaths: requested);
  }

  @override
  Future<void> downloadToFile(
    String path,
    UserSession session,
    File target, {
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {
    await target.parent.create(recursive: true);
    await target.writeAsBytes(<int>[1], flush: true);
    onProgress(1, 1);
  }
}
