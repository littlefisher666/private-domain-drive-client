import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/presentation/login_page.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';
import 'package:private_domain_drive_client/shared/state/app_scope.dart';

void main() {
  testWidgets('login page renders demo fields', (tester) async {
    final controller = AppController(sessionRepository: MemorySessionRepository());

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
    expect(find.textContaining('演示账号'), findsOneWidget);
  });
}
