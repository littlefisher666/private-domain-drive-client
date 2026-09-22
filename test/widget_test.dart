import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/presentation/login_page.dart';
import 'package:private_domain_drive_client/features/auth/presentation/change_password_page.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';
import 'package:private_domain_drive_client/shared/state/app_scope.dart';

void main() {
  testWidgets('登录页展示账号与口令输入项', (tester) async {
    final controller =
        AppController(sessionRepository: MemorySessionRepository());

    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: const MaterialApp(
          home: LoginPage(),
        ),
      ),
    );

    expect(find.text('成员账号'), findsOneWidget);
    expect(find.text('访问口令'), findsOneWidget);
    expect(find.text('请使用服务端已配置的账号和访问口令'), findsOneWidget);
  });

  testWidgets('改密页在本地拒绝短密码和不一致密码', (tester) async {
    final controller =
        AppController(sessionRepository: MemorySessionRepository());
    await controller.login(account: 'admin', password: '123456');
    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: const MaterialApp(home: ChangePasswordPage()),
      ),
    );

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '123456');
    await tester.enterText(fields.at(1), 'short');
    await tester.enterText(fields.at(2), 'short');
    await tester.tap(find.text('保存并进入文件空间'));
    await tester.pump();
    expect(find.text('新密码至少需要 8 个字符'), findsOneWidget);
  });
}
