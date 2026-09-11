import '../../core/network/api_client.dart';
import '../../core/version/app_version.dart';
import '../../features/auth/infrastructure/aliyun_sts_client.dart';
import '../../features/auth/infrastructure/secure_session_store.dart';
import '../../features/auth/infrastructure/session_repository.dart';
import '../../shared/state/app_controller.dart';

class AppBootstrap {
  AppBootstrap._();

  static late final AppController controller;

  static Future<AppController> initialize({
    SessionRepository? sessionRepository,
  }) async {
    final version = await PackageAppVersionReader().read();
    final repository = sessionRepository ??
        PersistentSessionRepository(
          store: SecureSessionStore(),
          apiClient: ApiClient(),
          stsClient: AliyunStsClient(),
          appVersion: version.name,
        );
    controller = AppController(sessionRepository: repository);
    await controller.bootstrap();
    return controller;
  }
}
