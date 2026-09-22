import 'package:flutter/material.dart';

import '../../features/auth/presentation/login_page.dart';
import '../../features/auth/presentation/change_password_page.dart';
import '../../features/auth/presentation/splash_page.dart';
import '../../features/preview/presentation/preview_page.dart';
import '../../features/settings/presentation/settings_page.dart';
import '../../features/share_import/presentation/share_confirm_page.dart';
import '../../features/transfer/presentation/transfer_tasks_page.dart';
import '../../features/workspace/presentation/home_shell.dart';
import '../../features/workspace/presentation/recycle_bin_page.dart';
import 'route_names.dart';

class AppRouter {
  AppRouter._();

  static const initialRoute = RouteNames.splash;

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case RouteNames.splash:
        return MaterialPageRoute<void>(
          builder: (_) => const SplashPage(),
          settings: settings,
        );
      case RouteNames.login:
        return MaterialPageRoute<void>(
          builder: (_) => const LoginPage(),
          settings: settings,
        );
      case RouteNames.changePassword:
        return MaterialPageRoute<void>(
          builder: (_) => ChangePasswordPage(
            forced: settings.arguments is bool
                ? settings.arguments as bool
                : true,
          ),
          settings: settings,
        );
      case RouteNames.home:
        final initialIndex =
            settings.arguments is int ? settings.arguments as int : 0;
        return MaterialPageRoute<void>(
          builder: (_) => HomeShell(initialIndex: initialIndex),
          settings: settings,
        );
      case RouteNames.workspace:
        return MaterialPageRoute<void>(
          builder: (_) => const HomeShell(),
          settings: settings,
        );
      case RouteNames.preview:
        final fileItem = settings.arguments as PreviewPageArguments?;
        return MaterialPageRoute<void>(
          builder: (_) => PreviewPage(arguments: fileItem),
          settings: settings,
        );
      case RouteNames.transfers:
        return MaterialPageRoute<void>(
          builder: (_) => const TransferTasksPage(),
          settings: settings,
        );
      case RouteNames.settings:
        return MaterialPageRoute<void>(
          builder: (_) => const SettingsPage(),
          settings: settings,
        );
      case RouteNames.shareConfirm:
        return MaterialPageRoute<void>(
          builder: (_) => const ShareConfirmPage(),
          settings: settings,
        );
      case RouteNames.recycleBin:
        return MaterialPageRoute<void>(
          builder: (_) => const RecycleBinPage(),
          settings: settings,
        );
      default:
        return MaterialPageRoute<void>(
          builder: (_) => const SplashPage(),
          settings: settings,
        );
    }
  }
}
