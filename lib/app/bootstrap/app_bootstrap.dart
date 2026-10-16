import '../../core/network/api_client.dart';
import '../../core/version/app_version.dart';
import '../../features/auth/infrastructure/saved_credentials_store.dart';
import '../../features/auth/infrastructure/secure_session_store.dart';
import '../../features/auth/infrastructure/session_repository.dart';
import '../../features/gallery/application/gallery_controller.dart';
import '../../shared/state/app_controller.dart';
import '../../shared/state/app_services.dart';

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
    // 装配层：AppServices 构造函数内创建 OssClient（单例注入全部控制器）、
    // 挂接 onCredentialExpired 与会话生命周期钩子（beforeSessionCleared/
    // onSessionChanged）、注入 UpdateService 与 disableStartupUpdateCheck。
    final services = AppServices(
      sessionRepository: repository,
      savedCredentialsStore: SavedCredentialsStore(),
    );
    controller = AppController.fromServices(services);
    galleryController = GalleryController(
      appController: controller,
      ossClient: services.ossClient,
    );
    controller.setGalleryHooks(galleryController);
    await controller.bootstrap();
    return controller;
  }
}
