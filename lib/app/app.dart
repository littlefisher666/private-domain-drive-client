import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'bootstrap/app_bootstrap.dart';
import '../features/gallery/presentation/gallery_scope.dart';
import '../features/settings/presentation/forced_upgrade_page.dart';
import '../features/share_import/domain/share_import_models.dart';
import '../features/share_import/infrastructure/android_share_import_bridge.dart';
import '../features/share_import/presentation/share_target_dialog.dart';
import '../shared/state/app_scope.dart';
import '../shared/state/app_services.dart';
import '../shared/widgets/app_feedback.dart';
import 'router/app_router.dart';
import 'router/route_names.dart';
import 'theme/app_theme.dart';
import 'theme/cupertino_desktop.dart';

class PrivateDomainDriveApp extends StatefulWidget {
  const PrivateDomainDriveApp({
    super.key,
    required this.services,
  });

  final AppServices services;

  @override
  State<PrivateDomainDriveApp> createState() => _PrivateDomainDriveAppState();
}

class _PrivateDomainDriveAppState extends State<PrivateDomainDriveApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<ShareImportEvent>? _shareSubscription;
  String? _openedShareSignature;
  bool _shareDialogShowing = false;
  bool? _lastLoggedIn;

  @override
  void initState() {
    super.initState();
    // 传输队列内的上传冲突处置对话框需要全局导航上下文。
    widget.services.setNavigatorKey(_navigatorKey);
    if (defaultTargetPlatform == TargetPlatform.android) {
      _shareSubscription = AndroidShareImportBridge.events.listen(
        _handleShareEvent,
        onError: (Object error) {
          debugPrint('[share-import] 分享事件流异常: $error');
        },
      );
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // 冷启动兜底：原生缓冲中已完整的批次直接并入为「立即完成」批次。
        final batches = await AndroidShareImportBridge.takePendingBatches();
        for (final batch in batches) {
          widget.services.shareImportController.addCompletedShareBatch(batch);
        }
        _showShareTargetDialogIfNeeded();
      });
    }
  }

  @override
  void dispose() {
    widget.services.setNavigatorKey(null);
    _shareSubscription?.cancel();
    super.dispose();
  }

  /// 信封事件分发：批次开始/逐项到达/批次完成均交给控制器渐进接收。
  void _handleShareEvent(ShareImportEvent event) {
    final shareImport = widget.services.shareImportController;
    switch (event) {
      case ShareImportBatchStart(:final batchId, :final total):
        shareImport.beginShareImportBatch(batchId, total);
      case ShareImportItemEvent(:final batchId, :final item):
        shareImport.addShareImportItem(batchId, item);
      case ShareImportBatchDone(
          :final batchId,
          :final succeeded,
          :final failed,
        ):
        shareImport.finishShareImportBatch(
          batchId,
          succeeded: succeeded,
          failed: failed,
        );
    }
    _showShareTargetDialogIfNeeded();
  }

  /// 分享进入后不落地中间页，直接弹目录选择框；弹窗可先于复制完成
  /// 弹出（进度在弹窗内展示），确认后立即开始上传。
  void _showShareTargetDialogIfNeeded() {
    final services = widget.services;
    final shareImport = services.shareImportController;
    if (_shareDialogShowing || !services.sessionController.isLoggedIn) {
      return;
    }
    // 防重入签名以批次 id 为准：同一批次不重复弹窗；取消弹窗时清除
    // 签名，重新分享同一批内容仍能再次弹出目录选择。
    final signature = shareImport.pendingShareBatchIds.join('|');
    if (signature.isEmpty || signature == _openedShareSignature) return;
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
    final shareImport = widget.services.shareImportController;
    final selected = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          ShareTargetDialog(initialPath: shareImport.shareTargetPath),
    );
    if (selected == null) {
      // 用户取消即放弃本次导入，避免残留待上传项；同时清除防重入签名
      // 与批次进度，让用户建完文件夹后重新分享仍能再次弹出目录选择。
      _openedShareSignature = null;
      shareImport.prepareShareImport(items: const <ShareImportItem>[]);
      return;
    }
    if (!context.mounted) return;
    final count = shareImport.pendingShareItems.length;
    shareImport.setShareTargetPath(selected);
    try {
      await shareImport.confirmShareUpload();
      if (context.mounted) {
        AppFeedback.showSnack(context, '已开始上传 $count 个文件');
      }
    } catch (error, stackTrace) {
      if (context.mounted) {
        AppFeedback.showError(context, error, stackTrace);
      }
    }
  }

  /// 会话因凭证失效被清除时，引导用户重新登录；启动阶段的初次路由
  /// 仍由 SplashPage 负责，这里只在「已登录 → 未登录」的迁移时介入。
  void _navigateToLoginOnSessionLoss() {
    final session = widget.services.sessionController;
    final loggedIn = session.isLoggedIn;
    final hadSession = _lastLoggedIn;
    _lastLoggedIn = loggedIn;
    if (session.bootstrapped && hadSession == true && !loggedIn) {
      _navigatorKey.currentState?.pushNamedAndRemoveUntil(
        RouteNames.login,
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
    final services = widget.services;
    return AppScope(
      services: services,
      child: GalleryScope(
        controller: AppBootstrap.galleryController,
        child: AnimatedBuilder(
        animation: services,
        builder: (context, _) {
          _showShareTargetDialogIfNeeded();
          _navigateToLoginOnSessionLoss();
          return MaterialApp(
            navigatorKey: _navigatorKey,
            title: '私域网盘',
            debugShowCheckedModeBanner: false,
            theme: isMacOS ? CupertinoDesktopTheme.light() : AppTheme.light(),
            darkTheme: isMacOS ? CupertinoDesktopTheme.dark() : AppTheme.dark(),
            themeMode: services.settingsController.themeMode,
            initialRoute: AppRouter.initialRoute,
            onGenerateRoute: AppRouter.onGenerateRoute,
            builder: (context, child) {
              // 强制升级拦截：以拦截页整体替换导航树（含所有路由与弹窗），
              // 门禁解除后恢复原界面；Nested Navigator 为拦截页提供
              // ModalRoute 祖先，使 PopScope 生效并向系统声明由框架处理
              // 返回。
              if (services.settingsController.forcedUpgradeActive) {
                return Navigator(
                  onGenerateRoute: (settings) => MaterialPageRoute<void>(
                    settings: settings,
                    builder: (_) => const ForcedUpgradePage(),
                  ),
                );
              }
              return child ?? const SizedBox.shrink();
            },
          );
        },
        ),
      ),
    );
  }
}
