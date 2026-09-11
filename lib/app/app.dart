import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../shared/state/app_controller.dart';
import '../shared/state/app_scope.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';
import 'theme/cupertino_desktop.dart';

class PrivateDomainDriveApp extends StatelessWidget {
  const PrivateDomainDriveApp({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
    return AppScope(
      controller: controller,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => MaterialApp(
          title: '私域网盘',
          debugShowCheckedModeBanner: false,
          theme: isMacOS ? CupertinoDesktopTheme.light() : AppTheme.light(),
          darkTheme: isMacOS ? CupertinoDesktopTheme.dark() : AppTheme.dark(),
          themeMode: controller.themeMode,
          initialRoute: AppRouter.initialRoute,
          onGenerateRoute: AppRouter.onGenerateRoute,
        ),
      ),
    );
  }
}
