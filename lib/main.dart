import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'app/app.dart';
import 'app/bootstrap/app_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final controller = await AppBootstrap.initialize();
  runApp(PrivateDomainDriveApp(controller: controller));
}
