import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/app/router/route_names.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/presentation/widgets/inline_rename_field.dart';

import 'support/workspace_test_harness.dart';

const _items = <FileItem>[
  FileItem(path: 'shared/资料/', name: '资料', isDirectory: true),
  FileItem(path: 'shared/doc.txt', name: 'doc.txt', isDirectory: false),
  FileItem(path: 'shared/pic.jpg', name: 'pic.jpg', isDirectory: false),
];

void _focusItems(WidgetTester tester) {
  tester
      .widget<Focus>(
        find.byKey(const ValueKey<String>('workspace-items-focus')),
      )
      .focusNode!
      .requestFocus();
}

Future<void> _selectItem(WidgetTester tester, String name) async {
  await tester.tap(find.text(name).first);
  // InkWell 同时提供 onTap/onDoubleTap 时会延迟触发单击，等待判定窗口。
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Space 预览当前选中的可预览文件', (tester) async {
    await pumpWorkspace(
      tester,
      _items,
      routes: <String, WidgetBuilder>{
        RouteNames.preview: (_) => const Scaffold(body: Text('预览页')),
      },
    );

    await _selectItem(tester, 'pic.jpg');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('预览页'), findsOneWidget);

    Navigator.of(tester.element(find.text('预览页'))).pop();
    await tester.pumpAndSettle();

    // 文件夹上的 Space 不触发预览。
    await _selectItem(tester, '资料');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.text('预览页'), findsNothing);
  });

  testWidgets('Enter 进入就地重命名', (tester) async {
    await pumpWorkspace(tester, _items);

    await _selectItem(tester, 'doc.txt');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(InlineRenameField), findsOneWidget);
  });

  testWidgets('Delete 展示回收站确认且取消不删除', (tester) async {
    await pumpWorkspace(tester, _items);

    await _selectItem(tester, 'doc.txt');
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('确认删除？')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: dialog, matching: find.text('取消')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('多选状态下 Delete 沿用批量确认', (tester) async {
    final controller = await pumpWorkspace(tester, _items);
    controller.workspaceController.selectAllItems(_items);
    await tester.pumpAndSettle();
    _focusItems(tester);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('确认删除 3 项？')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: dialog, matching: find.text('取消')));
    await tester.pumpAndSettle();
  });

  testWidgets('无删除权限时 Delete 只提示不弹确认', (tester) async {
    await pumpWorkspace(
      tester,
      _items,
      capabilities: const Capabilities(
        list: true,
        download: true,
        upload: true,
        delete: false,
        preview: true,
      ),
    );

    await _selectItem(tester, 'doc.txt');
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('当前身份没有删除权限'), findsOneWidget);
  });

  testWidgets('⌘R 重新加载当前目录', (tester) async {
    final oss = FakeWorkspaceOssClient(itemsByPath: <String, List<FileItem>>{
      'shared/': _items,
    });
    await pumpWorkspace(tester, _items, oss: oss);
    _focusItems(tester);
    await tester.pump();
    final callsBeforeRefresh = oss.listCalls;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(oss.listCalls, greaterThan(callsBeforeRefresh));
  });

  testWidgets('输入框聚焦时不触发文件区快捷键', (tester) async {
    final oss = FakeWorkspaceOssClient(itemsByPath: <String, List<FileItem>>{
      'shared/': _items,
    });
    await pumpWorkspace(
      tester,
      _items,
      oss: oss,
      routes: <String, WidgetBuilder>{
        RouteNames.preview: (_) => const Scaffold(body: Text('预览页')),
      },
    );
    await _selectItem(tester, 'doc.txt');
    final callsBeforeTyping = oss.listCalls;

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'doc');
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(find.byType(InlineRenameField), findsNothing);
    expect(find.text('预览页'), findsNothing);
    expect(oss.listCalls, callsBeforeTyping);
  });
}
