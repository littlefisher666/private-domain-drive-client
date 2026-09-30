import '../../core/network/api_client.dart';
import '../../core/version/app_version.dart';
import '../../features/auth/infrastructure/saved_credentials_store.dart';
import '../../features/auth/infrastructure/secure_session_store.dart';
import '../../features/auth/infrastructure/session_repository.dart';
import '../../features/gallery/application/gallery_controller.dart';
import '../../shared/state/app_controller.dart';

class AppBootstrap {
  AppBootstrap._();

  static late final AppController controller;
  static late final GalleryController galleryController;

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
    galleryController = GalleryController(
      appController: controller,
      ossClient: controller.ossClient,
    );
    controller.setGalleryHooks(galleryController);
    await controller.bootstrap();
    return controller;
  }
}
