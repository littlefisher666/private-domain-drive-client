import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/share_import/infrastructure/android_share_import_bridge.dart';
import '../shared/state/app_controller.dart';
import '../shared/state/app_scope.dart';
import 'router/app_router.dart';
import 'router/route_names.dart';
import 'theme/app_theme.dart';
import 'theme/cupertino_desktop.dart';

class PrivateDomainDriveApp extends StatefulWidget {
  const PrivateDomainDriveApp({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  State<PrivateDomainDriveApp> createState() => _PrivateDomainDriveAppState();
}

class _PrivateDomainDriveAppState extends State<PrivateDomainDriveApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<List<ShareImportItem>>? _shareSubscription;
  String? _openedShareSignature;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.android) {
      _shareSubscription = AndroidShareImportBridge.incomingItems.listen(
        _receiveSharedItems,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        _receiveSharedItems(await AndroidShareImportBridge.takePendingItems());
      });
    }
  }

  @override
  void dispose() {
    _shareSubscription?.cancel();
    super.dispose();
  }

  void _receiveSharedItems(List<ShareImportItem> items) {
    if (items.isEmpty) return;
    widget.controller.prepareShareImport(items: items);
    _showShareConfirmationIfPossible();
  }

  void _showShareConfirmationIfPossible() {
    if (!widget.controller.isLoggedIn ||
        widget.controller.pendingShareItems.isEmpty) {
      return;
    }
    final signature =
        widget.controller.pendingShareItems.map((item) => item.id).join('|');
    if (signature == _openedShareSignature) return;
    _openedShareSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigatorKey.currentState?.pushNamed(RouteNames.shareConfirm);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
    return AppScope(
      controller: widget.controller,
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          _showShareConfirmationIfPossible();
          return MaterialApp(
            navigatorKey: _navigatorKey,
            title: '私域网盘',
            debugShowCheckedModeBanner: false,
            theme: isMacOS ? CupertinoDesktopTheme.light() : AppTheme.light(),
            darkTheme: isMacOS ? CupertinoDesktopTheme.dark() : AppTheme.dark(),
            themeMode: widget.controller.themeMode,
            initialRoute: AppRouter.initialRoute,
            onGenerateRoute: AppRouter.onGenerateRoute,
          );
        },
      ),
    );
  }
}
