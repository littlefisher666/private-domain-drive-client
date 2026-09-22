import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter/foundation.dart';
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

const _downloadDirectoryPicker =
    MethodChannel('private_domain_drive/download_directory_picker');
String? _mockDownloadDirectory;

void main() {
  // bootstrap() 会读取 SharedPreferences；widget 测试的 FakeAsync 环境
  // 必须注入 mock，否则平台通道 Future 永远不会完成。
  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      _downloadDirectoryPicker,
      (_) async => _mockDownloadDirectory,
    );
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_downloadDirectoryPicker, null);
    _mockDownloadDirectory = null;
  });
  final items = <FileItem>[
    const FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
    const FileItem(path: 'shared/b.txt', name: 'b.txt', isDirectory: false),
    const FileItem(path: 'shared/c.txt', name: 'c.txt', isDirectory: false),
  ];

  testWidgets('桌面普通选择不显示条目复选框，批量选择可清空', (tester) async {
    final controller = await _pumpWorkspace(tester, items);

    expect(find.text('已全部加载，共 3 项'), findsOneWidget);
    expect(find.byType(Checkbox), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(controller.multiSelectedPaths, <String>{
      'shared/a.txt',
      'shared/b.txt',
      'shared/c.txt',
    });
    expect(find.text('已选 3 项'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(4));

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(controller.isMultiSelectionMode, isFalse);
    expect(find.text('已全部加载，共 3 项'), findsOneWidget);
  });

  testWidgets('桌面支持 Cmd+A 与表头三态全选', (tester) async {
    final controller = await _pumpWorkspace(tester, items);

    tester
        .widget<Focus>(
          find.byKey(const ValueKey<String>('workspace-items-focus')),
        )
        .focusNode!
        .requestFocus();

    // Cmd+A 触发全选。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.multiSelectedPaths.length, 3);
    expect(find.text('已选 3 项'), findsOneWidget);

    // 表头维持全选状态，点击后清空。
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(controller.multiSelectedPaths, isEmpty);
  });

  testWidgets('桌面批量勾选后按 Esc 清空选择', (tester) async {
    final controller = await _pumpWorkspace(tester, items);
    tester
        .widget<Focus>(
          find.byKey(const ValueKey<String>('workspace-items-focus')),
        )
        .focusNode!
        .requestFocus();
    controller.selectAllItems(items);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(controller.isMultiSelectionMode, isFalse);
    expect(controller.multiSelectedPaths, isEmpty);
    expect(find.byType(Checkbox), findsOneWidget);
  });

  testWidgets('桌面仅在主内容区获得焦点后响应上下方向键', (tester) async {
    final controller = await _pumpWorkspace(tester, items);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(controller.multiSelectedPaths, isEmpty);

    tester
        .widget<Focus>(
          find.byKey(const ValueKey<String>('workspace-items-focus')),
        )
        .focusNode!
        .requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(controller.selectedItem?.path, 'shared/b.txt');
    expect(controller.multiSelectedPaths, isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(controller.selectedItem?.path, 'shared/b.txt');
    expect(controller.multiSelectedPaths, isEmpty);
  });

  testWidgets('桌面主内容区支持 Cmd 加方向键进入和返回目录', (tester) async {
    const folder = FileItem(
      path: 'shared/资料/',
      name: '资料',
      isDirectory: true,
    );
    final oss = _FakeOssClient()
      ..itemsByPath['shared/'] = const <FileItem>[folder]
      ..itemsByPath['shared/资料/'] = const <FileItem>[];
    final controller = await _pumpWorkspace(
      tester,
      const <FileItem>[folder],
      oss: oss,
    );
    tester
        .widget<Focus>(
          find.byKey(const ValueKey<String>('workspace-items-focus')),
        )
        .focusNode!
        .requestFocus();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.currentPath, 'shared/资料/');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(controller.currentPath, AppController.rootPrefix);
  });

  testWidgets('桌面缩略图模式支持左右方向键切换条目', (tester) async {
    final controller = await _pumpWorkspace(tester, items);
    controller.setBrowseMode(BrowseMode.grid);
    await tester.pumpAndSettle();
    tester
        .widget<Focus>(
          find.byKey(const ValueKey<String>('workspace-items-focus')),
        )
        .focusNode!
        .requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(controller.selectedItem?.path, 'shared/b.txt');
    expect(controller.multiSelectedPaths, isEmpty);
  });

  testWidgets('桌面缩略图模式可切换大小，列表模式隐藏大小选择', (tester) async {
    final controller = await _pumpWorkspace(tester, items);
    controller.setBrowseMode(BrowseMode.grid);
    await tester.pumpAndSettle();

    expect(find.text('小'), findsOneWidget);
    expect(find.text('中'), findsOneWidget);
    expect(find.text('大'), findsOneWidget);

    await tester.tap(find.text('大'));
    await tester.pumpAndSettle();
    expect(controller.thumbnailSize, ThumbnailSize.large);

    controller.setBrowseMode(BrowseMode.list);
    await tester.pumpAndSettle();
    expect(find.text('小'), findsNothing);
    expect(find.text('中'), findsNothing);
    expect(find.text('大'), findsNothing);

    await controller.setThumbnailSize(ThumbnailSize.medium);
  });

  testWidgets('移动端中图与大图使用不同的网格列数', (tester) async {
    final controller = await _pumpWorkspace(tester, items, desktop: false);
    controller.setBrowseMode(BrowseMode.grid);
    await tester.pumpAndSettle();

    var grid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      2,
    );

    await tester.tap(find.byIcon(Icons.photo_size_select_large_outlined));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<ThumbnailSize>, '大图'),
    );
    await tester.pumpAndSettle();

    grid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      1,
    );
    await controller.setThumbnailSize(ThumbnailSize.medium);
  });

  testWidgets('桌面列表支持拖拽框选多个条目', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = await _pumpWorkspace(tester, items);

    final start = tester.getCenter(find.text('a.txt').first);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: start);
    await gesture.down(start);
    await gesture.moveBy(const Offset(8, 120));
    await tester.pump();
    await gesture.moveBy(const Offset(1, 1));
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();

    expect(controller.multiSelectedPaths,
        <String>{'shared/a.txt', 'shared/b.txt', 'shared/c.txt'});

    final clearGesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    const blankPosition = Offset(420, 520);
    await clearGesture.addPointer(location: blankPosition);
    await clearGesture.down(blankPosition);
    await clearGesture.up();
    await clearGesture.removePointer();
    await tester.pumpAndSettle();

    expect(controller.multiSelectedPaths, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('桌面宫格支持拖拽框选多个文件夹', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    const folders = <FileItem>[
      FileItem(path: 'shared/a/', name: 'a', isDirectory: true),
      FileItem(path: 'shared/b/', name: 'b', isDirectory: true),
      FileItem(path: 'shared/c/', name: 'c', isDirectory: true),
    ];
    final controller = await _pumpWorkspace(tester, folders);
    controller.setBrowseMode(BrowseMode.grid);
    await tester.pumpAndSettle();

    final start = tester.getCenter(find.text('a').first);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: start);
    await gesture.down(start);
    await gesture.moveBy(const Offset(520, 12));
    await tester.pump();
    await gesture.moveBy(const Offset(1, 1));
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();

    expect(controller.multiSelectedPaths,
        <String>{'shared/a/', 'shared/b/', 'shared/c/'});
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('桌面列表普通浏览时双击文件夹可进入目录', (tester) async {
    const directory = FileItem(
      path: 'shared/资料/',
      name: '资料',
      isDirectory: true,
    );
    final oss = _FakeOssClient()
      ..itemsByPath['shared/'] = const <FileItem>[directory]
      ..itemsByPath['shared/资料/'] = const <FileItem>[];
    final controller = await _pumpWorkspace(
      tester,
      const <FileItem>[directory],
      oss: oss,
    );

    final itemName = find.text('资料').first;
    await tester.tap(itemName);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(itemName);
    await tester.pumpAndSettle();

    expect(controller.currentPath, 'shared/资料/');
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

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('已选 3 项'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(controller.isMultiSelectionMode, isFalse);
  });

  testWidgets('批量下载展开文件夹入队并提示保留结构', (tester) async {
    final directory = Directory.systemTemp.createTempSync('pdd-batch-ui-');
    addTearDown(() => directory.deleteSync(recursive: true));
    _mockDownloadDirectory = directory.path;
    final originalPicker = FilePickerPlatform.instance;
    addTearDown(() => FilePickerPlatform.instance = originalPicker);
    FilePickerPlatform.instance = _FakeFilePicker(directory.path);

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
    final controller = await _pumpWorkspace(
        tester, <FileItem>[oss.itemsByPath['shared/']!.first, items.first],
        oss: oss);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.pump();

    // 提示已展开文件夹并保留结构，且多选状态被清理。
    expect(find.text('已加入 3 个下载任务，已保留文件夹结构'), findsOneWidget);
    expect(controller.isMultiSelectionMode, isFalse);
    final batchTasks = controller.tasks
        .where((task) => task.batchId != null)
        .toList(growable: false);
    expect(batchTasks, hasLength(3));
    expect(controller.transferBatches.single.total, 3);
  });

  testWidgets('批量下载空文件夹时提示没有可下载文件', (tester) async {
    final directory = Directory.systemTemp.createTempSync('pdd-empty-ui-');
    addTearDown(() => directory.deleteSync(recursive: true));
    _mockDownloadDirectory = directory.path;
    final originalPicker = FilePickerPlatform.instance;
    addTearDown(() => FilePickerPlatform.instance = originalPicker);
    FilePickerPlatform.instance = _FakeFilePicker(directory.path);

    final oss = _FakeOssClient()
      ..itemsByPath['shared/'] = <FileItem>[
        const FileItem(path: 'shared/空文件夹/', name: '空文件夹', isDirectory: true),
      ]
      ..objectKeysByPath['shared/空文件夹/'] = <String>['shared/空文件夹/'];
    final controller =
        await _pumpWorkspace(tester, oss.itemsByPath['shared/']!, oss: oss);

    await tester.tap(find.byType(Checkbox).first);
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
        tester,
        <FileItem>[
          oss.itemsByPath['shared/']!.first,
          oss.itemsByPath['shared/']!.last
        ],
        oss: oss);

    await tester.tap(find.byType(Checkbox).first);
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
      find.descendant(
        of: dialog,
        matching: find.textContaining('将移入回收站，30 天内可恢复'),
      ),
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
      ..firstDeleteFailures = <String>{'shared/资料/a.txt'};
    final controller = await _pumpWorkspace(
        tester, <FileItem>[oss.itemsByPath['shared/']!.first, items.first],
        oss: oss);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    final confirmDialog = find.byType(AlertDialog);
    await tester.tap(find
        .descendant(of: confirmDialog, matching: find.text('移入回收站')));
    // 确认按钮会触发异步批量删除；只推进当前帧，避免 settle 将后续
    // 刷新/反馈流程一并跑完，导致错过“部分删除失败”对话框。
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // 首次删除 2 项成功、1 项失败，展示部分失败反馈。
    final retryDialog = find.byType(AlertDialog);
    expect(retryDialog, findsOneWidget);
    expect(
      find.descendant(of: retryDialog, matching: find.text('部分删除失败')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: retryDialog, matching: find.textContaining('已删除 2 项，1 项失败')),
      findsOneWidget,
    );

    await tester
        .tap(find.descendant(of: retryDialog, matching: find.text('重试失败项')));
    await tester.pumpAndSettle();

    expect(oss.deleteManyCalls, 2);
    expect(find.text('已移入回收站 3 项'), findsOneWidget);
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
    ossClient: oss ?? _FakeOssClient()
      ..itemsByPath['shared/'] = files,
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

class _FakeFilePicker extends FilePickerPlatform {
  _FakeFilePicker(this.directoryPath);

  final String? directoryPath;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
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
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<void> copy(String from, String to, UserSession session) async {}

  @override
  Future<void> uploadText(
      String path, String content, UserSession session) async {}

  @override
  Future<List<FileItem>> list(String path, UserSession session) async =>
      itemsByPath[path] ?? const <FileItem>[];

  @override
  Future<List<String>> listAllObjectKeys(String path, UserSession session) =>
      Future<void>.value()
          .then((_) => objectKeysByPath[path] ?? const <String>[]);

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
    required String taskId,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {
    await target.parent.create(recursive: true);
    await target.writeAsBytes(<int>[1], flush: true);
    onProgress(1, 1);
  }

  @override
  Future<void> clearConfiguration() async {}

  @override
  Future<void> cancelTransfer(String taskId) async {}
}
