import '../../core/network/api_client.dart';
import '../../core/version/app_version.dart';
import '../../features/auth/infrastructure/saved_credentials_store.dart';
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
          appVersion: version.name,
        );
    controller = AppController(
      sessionRepository: repository,
      savedCredentialsStore: SavedCredentialsStore(),
    );
    await controller.bootstrap();
    return controller;
  }
}
