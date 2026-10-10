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
  final controller = await AppBootstrap.initialize();
  runApp(PrivateDomainDriveApp(controller: controller));
  if (!kIsWeb &&
      Platform.isMacOS &&
      !AppConstants.disableStartupUpdateCheck &&
      controller.autoCheckUpdates) {
    unawaited(
        MacosSparkleUpdater.instance.startupCheck().catchError((Object _) {}));
  }
}
