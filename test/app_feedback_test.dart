import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/core/errors/app_error.dart';
import 'package:private_domain_drive_client/shared/widgets/app_feedback.dart';

void main() {
  test('业务异常使用自带文案', () {
    expect(
      userFacingErrorMessage(AppError('分享准备失败')),
      '分享准备失败',
    );
    expect(
      userFacingErrorMessage(StateError('名称已存在')),
      '名称已存在',
    );
  });

  test('未知异常统一为通用提示', () {
    expect(
      userFacingErrorMessage(Exception('SocketException: failed host lookup')),
      '操作失败，请稍后重试',
    );
    expect(
      userFacingErrorMessage(ArgumentError('invalid value')),
      '操作失败，请稍后重试',
    );
  });

  test('AppFeedback.errorMessage 与统一文案保持一致', () {
    expect(
      AppFeedback.errorMessage(AppError('目标目录不存在')),
      '目标目录不存在',
    );
    expect(
      AppFeedback.errorMessage(Exception('boom')),
      '操作失败，请稍后重试',
    );
  });

  testWidgets('showError 展示用户文案而非异常字符串', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => AppFeedback.showError(
                context,
                AppError('当前身份没有删除权限'),
              ),
              child: const Text('触发'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('触发'));
    await tester.pump();
    expect(find.text('当前身份没有删除权限'), findsOneWidget);
    expect(find.textContaining('AppError'), findsNothing);
  });

  testWidgets('未知异常在提示层不暴露技术细节', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => AppFeedback.showError(
                context,
                Exception('SocketException: Connection refused'),
              ),
              child: const Text('触发'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('触发'));
    await tester.pump();
    expect(find.text('操作失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('SocketException'), findsNothing);
  });
}
