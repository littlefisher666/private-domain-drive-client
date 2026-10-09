import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/preview/presentation/preview_page.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';
import 'package:private_domain_drive_client/shared/state/app_scope.dart';

void main() {
  Future<void> pumpPreview(
    WidgetTester tester, {
    required String fileName,
  }) {
    return tester.pumpWidget(
      AppScope(
        controller: AppController(sessionRepository: MemorySessionRepository()),
        child: MaterialApp(
          home: PreviewPage(
            arguments: PreviewPageArguments(
              fileName: fileName,
              filePath: 'shared/$fileName',
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('图片文件显示图片预览', (tester) async {
    await pumpPreview(tester, fileName: '照片.jpg');

    expect(find.text('照片.jpg'), findsWidgets);
  });

  testWidgets('PDF 文件进入 PDF 预览组件（未登录显示加载失败可重试）', (tester) async {
    await pumpPreview(tester, fileName: '说明.pdf');
    await tester.pumpAndSettle();

    expect(find.text('说明.pdf'), findsWidgets);
    expect(find.text('PDF 预览加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('文本文件进入文本预览组件（未登录显示加载失败可重试）', (tester) async {
    await pumpPreview(tester, fileName: '说明.txt');
    await tester.pumpAndSettle();

    expect(find.text('说明.txt'), findsWidgets);
    expect(find.text('文本预览加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('Markdown 文件进入 Markdown 预览组件（未登录显示加载失败可重试）', (tester) async {
    await pumpPreview(tester, fileName: '说明.md');
    await tester.pumpAndSettle();

    expect(find.text('说明.md'), findsWidgets);
    expect(find.text('Markdown 预览加载失败'), findsOneWidget);
  });

  testWidgets('音频文件进入音频预览组件（未登录显示加载失败可重试）', (tester) async {
    await pumpPreview(tester, fileName: '歌曲.mp3');
    await tester.pumpAndSettle();

    expect(find.text('歌曲.mp3'), findsWidgets);
    expect(find.text('音频加载失败'), findsOneWidget);
  });

  testWidgets('不支持文件提示仅可下载', (tester) async {
    await pumpPreview(tester, fileName: '归档.zip');

    expect(find.text('暂不支持预览'), findsOneWidget);
    expect(find.textContaining('当前类型仅支持下载'), findsOneWidget);
  });
}
