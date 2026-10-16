import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/application/session_controller.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/saved_credentials_store.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';

void main() {
  group('SessionController', () {
    test('登录失败会返回明确错误', () async {
      final controller = SessionController(
        sessionRepository: MemorySessionRepository(),
        ossClient: OssClient(),
        savedCredentialsStore:
            SavedCredentialsStore(storage: InMemoryCredentialsStorage()),
      );

      final result = await controller.login(account: 'admin', password: '错误密码');

      expect(result.ok, isFalse);
      expect(result.message, '用户名或密码错误');
    });

    test('登录成功后记住最近登录凭据', () async {
      final controller = SessionController(
        sessionRepository: MemorySessionRepository(),
        ossClient: OssClient(),
        savedCredentialsStore:
            SavedCredentialsStore(storage: InMemoryCredentialsStorage()),
      );

      await controller.login(account: ' admin ', password: '123456');

      final credentials = await controller.readSavedCredentials();
      expect(credentials, isNotNull);
      expect(credentials!.account, 'admin');
      expect(credentials.password, '123456');
    });

    test('修改密码成功后同步更新记住的密码', () async {
      final controller = SessionController(
        sessionRepository: MemorySessionRepository(),
        ossClient: OssClient(),
        savedCredentialsStore:
            SavedCredentialsStore(storage: InMemoryCredentialsStorage()),
      );
      await controller.login(account: 'admin', password: '123456');

      final error = await controller.changePassword(
        currentPassword: '123456',
        newPassword: 'newpassword1',
      );

      expect(error, isNull);
      final credentials = await controller.readSavedCredentials();
      expect(credentials, isNotNull);
      expect(credentials!.account, 'admin');
      expect(credentials.password, 'newpassword1');
    });
  });
}
