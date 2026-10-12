import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'bootstrap/app_bootstrap.dart';
import '../features/gallery/presentation/gallery_scope.dart';
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
  StreamSubscription<ShareImportEvent>? _shareSubscription;
  String? _openedShareSignature;
  bool _shareDialogShowing = false;
  bool? _lastLoggedIn;

  @override
  void initState() {
    super.initState();
    // 传输队列内的上传冲突处置对话框需要全局导航上下文。
    widget.controller.setNavigatorKey(_navigatorKey);
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
          widget.controller.addCompletedShareBatch(batch);
        }
        _showShareTargetDialogIfNeeded();
      });
    }
  }

  @override
  void dispose() {
    widget.controller.setNavigatorKey(null);
    _shareSubscription?.cancel();
    super.dispose();
  }

  /// 信封事件分发：批次开始/逐项到达/批次完成均交给控制器渐进接收。
  void _handleShareEvent(ShareImportEvent event) {
    final controller = widget.controller;
    switch (event) {
      case ShareImportBatchStart(:final batchId, :final total):
        controller.beginShareImportBatch(batchId, total);
      case ShareImportItemEvent(:final batchId, :final item):
        controller.addShareImportItem(batchId, item);
      case ShareImportBatchDone(
          :final batchId,
          :final succeeded,
          :final failed,
        ):
        controller.finishShareImportBatch(
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
    final controller = widget.controller;
    if (_shareDialogShowing || !controller.isLoggedIn) {
      return;
    }
    // 防重入签名以批次 id 为准：同一批次不重复弹窗；取消弹窗时清除
    // 签名，重新分享同一批内容仍能再次弹出。
    final signature = controller.pendingShareBatchIds.join('|');
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
    final controller = widget.controller;
    final selected = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          ShareTargetDialog(initialPath: controller.shareTargetPath),
    );
    if (selected == null) {
      // 用户取消即放弃本次导入，避免残留待上传项；同时清除防重入签名
      // 与批次进度，让用户建完文件夹后重新分享仍能再次弹出目录选择。
      _openedShareSignature = null;
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
      child: GalleryScope(
        controller: AppBootstrap.galleryController,
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
      ),
    );
  }
}
