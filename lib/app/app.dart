import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/share_import/infrastructure/android_share_import_bridge.dart';
import '../features/share_import/presentation/share_target_dialog.dart';
import '../shared/state/app_controller.dart';
import '../shared/state/app_scope.dart';
import '../shared/widgets/app_feedback.dart';
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
  bool _shareDialogShowing = false;
  bool? _lastLoggedIn;

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
    _showShareTargetDialogIfNeeded();
  }

  /// 分享进入后不落地中间页，直接弹目录选择框；确认后立即开始上传。
  void _showShareTargetDialogIfNeeded() {
    if (_shareDialogShowing ||
        !widget.controller.isLoggedIn ||
        widget.controller.pendingShareItems.isEmpty) {
      return;
    }
    final signature =
        widget.controller.pendingShareItems.map((item) => item.id).join('|');
    if (signature == _openedShareSignature) return;
    _openedShareSignature = signature;
    _shareDialogShowing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _runShareImport();
      } finally {
        _shareDialogShowing = false;
      }
    });
  }

  Future<void> _runShareImport() async {
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    final controller = widget.controller;
    final selected = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          ShareTargetDialog(initialPath: controller.shareTargetPath),
    );
    if (selected == null) {
      // 用户取消即放弃本次导入，避免残留待上传项。
      controller.prepareShareImport(items: const <ShareImportItem>[]);
      return;
    }
    if (!context.mounted) return;
    final count = controller.pendingShareItems.length;
    controller.setShareTargetPath(selected);
    try {
      await controller.confirmShareUpload();
      if (context.mounted) {
        AppFeedback.showSnack(context, '已开始上传 $count 个文件');
      }
    } catch (error) {
      if (context.mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  /// 会话因凭证失效被清除时，引导用户重新登录；启动阶段的初次路由
  /// 仍由 SplashPage 负责，这里只在「已登录 → 未登录」的迁移时介入。
  void _navigateToLoginOnSessionLoss() {
    final loggedIn = widget.controller.isLoggedIn;
    final hadSession = _lastLoggedIn;
    _lastLoggedIn = loggedIn;
    if (widget.controller.bootstrapped &&
        hadSession == true &&
        !loggedIn) {
      _navigatorKey.currentState?.pushNamedAndRemoveUntil(
        RouteNames.login,
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
    return AppScope(
      controller: widget.controller,
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          _showShareTargetDialogIfNeeded();
          _navigateToLoginOnSessionLoss();
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
