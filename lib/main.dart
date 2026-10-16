import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'app/app.dart';
import 'app/bootstrap/app_bootstrap.dart';
import 'core/constants/app_constants.dart';
import 'features/settings/infrastructure/macos_sparkle_updater.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final services = await AppBootstrap.initialize();
  runApp(PrivateDomainDriveApp(services: services));
  // 两端统一的启动静默门禁检查：不阻塞启动、失败放行；调试开关同时关闭该检查。
  unawaited(services.settingsController.checkForcedUpgradeGate());
  if (!kIsWeb &&
      Platform.isMacOS &&
      !AppConstants.disableStartupUpdateCheck &&
      services.settingsController.autoCheckUpdates) {
    unawaited(
        MacosSparkleUpdater.instance.startupCheck().catchError((Object _) {}));
  }
}
