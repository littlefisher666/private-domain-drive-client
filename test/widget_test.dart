import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/app/router/route_names.dart';
import 'package:private_domain_drive_client/features/auth/presentation/login_page.dart';
import 'package:private_domain_drive_client/features/auth/presentation/change_password_page.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/saved_credentials_store.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';
import 'package:private_domain_drive_client/shared/state/app_scope.dart';

void main() {
  AppController controllerWithMemoryStore() => AppController(
        sessionRepository: MemorySessionRepository(),
        savedCredentialsStore:
            SavedCredentialsStore(storage: InMemoryCredentialsStorage()),
      );

  Future<AppController> loggedInController() async {
    final controller = controllerWithMemoryStore();
    await controller.login(account: 'admin', password: '123456');
    return controller;
  }

  testWidgets('登录页展示用户名与密码输入项', (tester) async {
    final controller = controllerWithMemoryStore();

    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: const MaterialApp(
          home: LoginPage(),
        ),
      ),
    );

    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('忘记密码？请联系管理员重置'), findsOneWidget);
  });

  testWidgets('登录页预填最近一次成功登录的凭据', (tester) async {
    final controller = AppController(
      sessionRepository: MemorySessionRepository(),
      savedCredentialsStore: SavedCredentialsStore(
        storage: InMemoryCredentialsStorage(initialValues: <String, String>{
          'pdd.saved_credentials.v1': jsonEncode(<String, String>{
            'account': 'member',
            'password': 'remembered-pass',
          }),
        }),
      ),
    );

    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: const MaterialApp(
          home: LoginPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller!.text, 'member');
    expect(
      tester.widget<TextField>(fields.at(1)).controller!.text,
      'remembered-pass',
    );
  });

  testWidgets('改密页在本地拒绝短密码和不一致密码', (tester) async {
    final controller = await loggedInController();
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

  testWidgets('主动改密页在本地拒绝两次输入不一致', (tester) async {
    final controller = await loggedInController();
    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: const MaterialApp(home: ChangePasswordPage(forced: false)),
      ),
    );

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '123456');
    await tester.enterText(fields.at(1), 'newpassword1');
    await tester.enterText(fields.at(2), 'newpassword2');
    await tester.tap(find.text('保存修改'));
    await tester.pump();
    expect(find.text('两次输入的新密码不一致'), findsOneWidget);
  });

  testWidgets('主动改密当前密码错误时提示失败并停留', (tester) async {
    final controller = await loggedInController();
    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: const MaterialApp(home: ChangePasswordPage(forced: false)),
      ),
    );

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'wrong-password');
    await tester.enterText(fields.at(1), 'newpassword1');
    await tester.enterText(fields.at(2), 'newpassword1');
    await tester.tap(find.text('保存修改'));
    await tester.pump();
    expect(find.text('当前密码错误'), findsOneWidget);
    expect(find.byType(ChangePasswordPage), findsOneWidget);
  });

  testWidgets('主动改密成功后返回设置页', (tester) async {
    final controller = await loggedInController();
    await tester.pumpWidget(
      AppScope(
        controller: controller,
        child: MaterialApp(
          routes: {
            RouteNames.changePassword: (_) =>
                const ChangePasswordPage(forced: false),
          },
          home: Scaffold(
            body: Column(
              children: [
                const Text('设置页'),
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context)
                        .pushNamed(RouteNames.changePassword, arguments: false),
                    child: const Text('打开修改密码'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开修改密码'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '123456');
    await tester.enterText(fields.at(1), 'newpassword1');
    await tester.enterText(fields.at(2), 'newpassword1');
    await tester.tap(find.text('保存修改'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('设置页'), findsOneWidget);
    expect(find.byType(ChangePasswordPage), findsNothing);
    expect(controller.session?.mustResetPassword, isFalse);
  });
}
