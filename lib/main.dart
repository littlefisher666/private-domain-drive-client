import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'app/bootstrap/app_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await AppBootstrap.initialize();
  runApp(PrivateDomainDriveApp(controller: controller));
}
