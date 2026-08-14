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

    expect(find.text('图片预览'), findsOneWidget);
    expect(find.text('文件：照片.jpg'), findsOneWidget);
  });

  testWidgets('PDF 文件显示 PDF 预览', (tester) async {
    await pumpPreview(tester, fileName: '说明.pdf');

    expect(find.text('PDF 预览'), findsOneWidget);
    expect(find.text('说明.pdf'), findsWidgets);
  });

  testWidgets('文本文件显示文本预览', (tester) async {
    await pumpPreview(tester, fileName: '说明.txt');

    expect(find.text('文本预览'), findsOneWidget);
    expect(find.textContaining('暂不支持在线读取'), findsOneWidget);
  });

  testWidgets('不支持文件提示仅可下载', (tester) async {
    await pumpPreview(tester, fileName: '归档.zip');

    expect(find.text('暂不支持预览'), findsOneWidget);
    expect(find.textContaining('当前类型仅支持下载'), findsOneWidget);
  });
}
