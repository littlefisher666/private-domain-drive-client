import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/file_share/domain/file_share_models.dart';
import 'package:private_domain_drive_client/features/file_share/presentation/share_prepare_dialog.dart';

void main() {
  testWidgets('展示文件名与进度，取消触发回调，进度置空后关闭', (tester) async {
    final progress = ValueNotifier<ShareProgress?>(
      const ShareProgress(
        fileName: '报告.pdf',
        receivedBytes: 0,
        totalBytes: 100,
      ),
    );
    var cancelCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => SharePrepareDialog(
                    progress: progress,
                    onCancel: () => cancelCount++,
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('报告.pdf'), findsOneWidget);
    expect(find.textContaining('已传输 0 B'), findsOneWidget);

    progress.value = const ShareProgress(
      fileName: '报告.pdf',
      receivedBytes: 50,
      totalBytes: 100,
    );
    await tester.pump();
    expect(find.textContaining('已传输 50 B'), findsOneWidget);
    expect(find.textContaining('100 B'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(cancelCount, 1);
    expect(find.byType(SharePrepareDialog), findsOneWidget);

    progress.value = null;
    await tester.pumpAndSettle();
    expect(find.byType(SharePrepareDialog), findsNothing);

    progress.dispose();
  });

  testWidgets('多文件展示批次序号与累计进度', (tester) async {
    final progress = ValueNotifier<ShareProgress?>(
      const ShareProgress(
        fileName: 'b.pdf',
        receivedBytes: 50,
        totalBytes: 100,
        fileIndex: 2,
        fileCount: 3,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SharePrepareDialog(
            progress: progress,
            onCancel: () {},
          ),
        ),
      ),
    );

    expect(find.text('第 2/3 个：b.pdf'), findsOneWidget);
    expect(find.textContaining('已传输 50 B'), findsOneWidget);
    expect(find.textContaining('100 B'), findsOneWidget);

    progress.dispose();
  });

  testWidgets('未知总大小时展示不确定进度条', (tester) async {
    final progress = ValueNotifier<ShareProgress?>(
      const ShareProgress(fileName: 'a.bin', receivedBytes: 12),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SharePrepareDialog(
            progress: progress,
            onCancel: () {},
          ),
        ),
      ),
    );

    expect(find.textContaining('未知大小'), findsOneWidget);
    final indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, isNull);

    progress.dispose();
  });
}
