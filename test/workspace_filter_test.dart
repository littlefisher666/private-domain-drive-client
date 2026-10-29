import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/presentation/recycle_bin_page.dart';
import 'package:private_domain_drive_client/features/workspace/presentation/widgets/cupertino_segmented.dart';
import 'package:private_domain_drive_client/features/workspace/presentation/workspace_page.dart';

import 'support/workspace_test_harness.dart';

const _items = <FileItem>[
  FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
  FileItem(path: 'shared/b.txt', name: 'b.txt', isDirectory: false),
  FileItem(path: 'shared/notes.md', name: 'notes.md', isDirectory: false),
];

void main() {
  testWidgets('桌面输入关键字不区分大小写过滤当前目录', (tester) async {
    await pumpWorkspace(tester, _items);

    await tester.enterText(find.byType(TextField), 'B.TXT');
    await tester.pumpAndSettle();

    expect(find.text('b.txt'), findsWidgets);
    expect(find.text('a.txt'), findsNothing);
    expect(find.text('notes.md'), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('a.txt'), findsWidgets);
    expect(find.text('b.txt'), findsWidgets);
    expect(find.text('notes.md'), findsWidgets);
  });

  testWidgets('筛选不递归匹配子目录且不发起额外列举', (tester) async {
    const folder = FileItem(
      path: 'shared/docs/',
      name: 'docs',
      isDirectory: true,
    );
    final oss = FakeWorkspaceOssClient(itemsByPath: <String, List<FileItem>>{
      'shared/': const <FileItem>[folder, ..._items],
      // 子目录内部存在匹配文件，但目录名称本身不匹配。
      'shared/docs/': const <FileItem>[
        FileItem(path: 'shared/docs/match.txt', name: 'match.txt', isDirectory: false),
      ],
    });
    await pumpWorkspace(tester, const <FileItem>[folder, ..._items], oss: oss);
    final callsBeforeFilter = oss.listCalls;

    await tester.enterText(find.byType(TextField), 'match');
    await tester.pumpAndSettle();

    expect(find.text('docs'), findsNothing);
    expect(find.text('a.txt'), findsNothing);
    expect(oss.listCalls, callsBeforeFilter);
  });

  testWidgets('无匹配时展示清除筛选入口而不是空目录引导', (tester) async {
    await pumpWorkspace(tester, _items);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();

    expect(find.text('没有匹配“zzz”的条目'), findsOneWidget);
    expect(find.text('当前目录为空'), findsNothing);

    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(find.text('a.txt'), findsWidgets);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
  });

  testWidgets('筛选后全选只选中当前可见条目', (tester) async {
    final controller = await pumpWorkspace(tester, _items);

    await tester.enterText(find.byType(TextField), 'a');
    await tester.pumpAndSettle();
    tester
        .widget<Focus>(
          find.byKey(const ValueKey<String>('workspace-items-focus')),
        )
        .focusNode!
        .requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(controller.workspaceController.multiSelectedPaths,
        <String>{'shared/a.txt'});
    expect(find.text('已选 1 项'), findsOneWidget);
  });

  testWidgets('筛选变化时裁剪已有多选集合', (tester) async {
    final controller = await pumpWorkspace(tester, _items);
    controller.workspaceController.selectAllItems(_items);
    await tester.pumpAndSettle();
    expect(find.text('已选 3 项'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'notes');
    await tester.pumpAndSettle();

    expect(controller.workspaceController.multiSelectedPaths,
        <String>{'shared/notes.md'});
    expect(find.text('已选 1 项'), findsOneWidget);
  });

  testWidgets('切换目录清空筛选并展示新目录完整列表', (tester) async {
    const folder = FileItem(
      path: 'shared/资料/',
      name: '资料',
      isDirectory: true,
    );
    final oss = FakeWorkspaceOssClient(itemsByPath: <String, List<FileItem>>{
      'shared/': const <FileItem>[folder, ..._items],
      'shared/资料/': const <FileItem>[
        FileItem(
          path: 'shared/资料/other.txt',
          name: 'other.txt',
          isDirectory: false,
        ),
      ],
    });
    await pumpWorkspace(tester, const <FileItem>[folder, ..._items], oss: oss);

    await tester.enterText(find.byType(TextField), '资料');
    await tester.pumpAndSettle();
    expect(find.text('a.txt'), findsNothing);

    final folderName = find
        .descendant(
          of: find.byType(WorkspaceListView),
          matching: find.text('资料'),
        )
        .first;
    await tester.tap(folderName);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(folderName);
    await tester.pumpAndSettle();

    expect(find.text('other.txt'), findsWidgets);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
  });

  testWidgets('桌面工具栏筛选框与左右控件等高', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpWorkspace(tester, _items);

    double heightOf(Finder finder) => tester.getSize(finder.first).height;
    final segmentedHeight = heightOf(find.byType(CupertinoSegmented));
    final filterHeight = heightOf(
      find.ancestor(
        of: find.byType(TextField),
        matching: find.byType(DecoratedBox),
      ),
    );
    final sortHeight = heightOf(
      find.descendant(
        of: find.byType(PopupMenuButton<FileSortOption>),
        matching: find.byType(Material),
      ),
    );
    final refreshHeight = heightOf(
      find.descendant(
        of: find.widgetWithText(OutlinedButton, '刷新'),
        matching: find.byType(Material),
      ),
    );

    expect(filterHeight, segmentedHeight);
    expect(sortHeight, segmentedHeight);
    expect(refreshHeight, segmentedHeight);
  });

  testWidgets('移动端页头搜索入口可展开并过滤列表', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpWorkspace(tester, _items, desktop: false);

    await tester.tap(find.byTooltip('筛选当前目录'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'notes');
    await tester.pumpAndSettle();
    expect(find.text('notes.md'), findsWidgets);
    expect(find.text('a.txt'), findsNothing);

    await tester.tap(find.byTooltip('关闭筛选'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('a.txt'), findsWidgets);
  });

  testWidgets('移动端进入子目录后标题保持单行', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    const folder = FileItem(
      path: 'shared/资料/',
      name: '资料',
      isDirectory: true,
    );
    final oss = FakeWorkspaceOssClient(itemsByPath: <String, List<FileItem>>{
      'shared/': const <FileItem>[folder, ..._items],
      'shared/资料/': const <FileItem>[
        FileItem(
          path: 'shared/资料/other.txt',
          name: 'other.txt',
          isDirectory: false,
        ),
      ],
    });
    final controller = await pumpWorkspace(
      tester,
      const <FileItem>[folder, ..._items],
      desktop: false,
      oss: oss,
    );

    final headerTitle = find.text('共享空间');
    expect(headerTitle, findsOneWidget);
    controller.workspaceController.setCurrentPath('shared/资料/');
    await tester.pumpAndSettle();

    // 返回按钮出现后图标区占用变宽，标题仍须保持单行（不换行）。
    expect(find.text('共享空间'), findsOneWidget);
    expect(tester.getSize(headerTitle).height, lessThan(40));
  });

  testWidgets('移动端下拉刷新重新加载当前目录', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final oss = FakeWorkspaceOssClient(itemsByPath: <String, List<FileItem>>{
      'shared/': _items,
    });
    await pumpWorkspace(tester, _items, desktop: false, oss: oss);
    final callsBeforeRefresh = oss.listCalls;

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(oss.listCalls, greaterThan(callsBeforeRefresh));
    expect(find.text('a.txt'), findsWidgets);
  });

  testWidgets('下拉刷新失败保留旧列表并给出通用提示', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final oss = FakeWorkspaceOssClient(itemsByPath: <String, List<FileItem>>{
      'shared/': _items,
    });
    await pumpWorkspace(tester, _items, desktop: false, oss: oss);
    oss.listError = Exception('network down');

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('a.txt'), findsWidgets);
    expect(find.text('操作失败，请稍后重试'), findsOneWidget);
  });

  testWidgets('移动端回收站列表支持下拉刷新', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final oss = FakeWorkspaceOssClient();
    await pumpApp(tester, const RecycleBinPage(embedded: true), oss: oss);
    expect(find.byType(RefreshIndicator), findsOneWidget);
    final callsBeforeRefresh = oss.listPrefixCalls;

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(oss.listPrefixCalls, greaterThan(callsBeforeRefresh));
  });
}
