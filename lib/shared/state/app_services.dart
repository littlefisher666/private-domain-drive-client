import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/auth/application/session_controller.dart';
import '../../features/auth/infrastructure/saved_credentials_store.dart';
import '../../features/auth/infrastructure/session_repository.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/settings/application/update_service.dart';
import '../../features/share_import/application/share_import_controller.dart';
import '../../features/transfer/application/transfer_controller.dart';
import '../../features/transfer/application/transfer_queue.dart';
import '../../features/transfer/infrastructure/upload_staging.dart';
import '../../features/workspace/application/alias_controller.dart';
import '../../features/workspace/application/move_controller.dart';
import '../../features/workspace/application/recycle_bin_controller.dart';
import '../../features/workspace/application/workspace_controller.dart';
import '../../features/workspace/infrastructure/alias_repository.dart';
import '../../features/workspace/infrastructure/oss_client.dart';
import '../gallery_index_hooks.dart';
import '../transfer_keepalive.dart';

/// 应用控制器聚合层：持有并装配全部子控制器，向外提供统一的
/// 生命周期入口（[bootstrap]/[dispose]）与装配 setter。
///
/// 装配策略（原门面已拆除，装配收敛于本类）：
/// - [OssClient] 创建一次，注入所有需要直连 OSS 的控制器；
/// - `onCredentialExpired` 指向 [SessionController.handleCredentialExpired]；
/// - 会话生命周期钩子（beforeSessionCleared/onSessionChanged）在本层编排
///   跨域复位逻辑；
/// - 订阅各 ChangeNotifier 子控制器并转发 `notifyListeners`
///   （[TransferQueue] 非 ChangeNotifier，经 ValueNotifier 对外暴露状态，
///   与原门面保持一致不参与监听链）。
class AppServices extends ChangeNotifier {
  AppServices({
    required SessionRepository sessionRepository,
    OssClient? ossClient,
    SavedCredentialsStore? savedCredentialsStore,
    UploadStaging? uploadStaging,
    TransferKeepaliveService? transferKeepalive,
    UpdateService? updateService,
    bool? disableStartupUpdateCheck,
  }) : ossClient = ossClient ?? OssClient() {
    // 构造后统一使用字段（参数可能为 null，字段已兜底创建）。
    final client = this.ossClient;
    sessionController = SessionController(
      sessionRepository: sessionRepository,
      ossClient: client,
      savedCredentialsStore: savedCredentialsStore,
    )
      ..beforeSessionCleared = _handleBeforeSessionCleared
      ..onSessionChanged = _handleSessionChanged
      ..addListener(notifyListeners);
    client.onCredentialExpired = sessionController.handleCredentialExpired;
    workspaceController = WorkspaceController(
      sessionController: sessionController,
      ossClient: client,
    )..addListener(notifyListeners);
    transferQueue = TransferQueue(
      transferKeepalive: transferKeepalive ?? createTransferKeepaliveService(),
    );
    transferController = TransferController(
      sessionController: sessionController,
      workspaceController: workspaceController,
      transferQueue: transferQueue,
      ossClient: client,
      uploadStaging: uploadStaging,
    )..addListener(notifyListeners);
    shareImportController = ShareImportController(
      sessionController: sessionController,
      workspaceController: workspaceController,
      transferController: transferController,
    )..addListener(notifyListeners);
    moveController = MoveController(
      sessionController: sessionController,
      workspaceController: workspaceController,
      ossClient: client,
    )..addListener(notifyListeners);
    recycleBinController = RecycleBinController(
      sessionController: sessionController,
      workspaceController: workspaceController,
      ossClient: client,
    )..addListener(notifyListeners);
    aliasController = AliasController(
      sessionController: sessionController,
      workspaceController: workspaceController,
      aliasRepository: AliasRepository(ossClient: client),
      ossClient: client,
    )..addListener(notifyListeners);
    settingsController = SettingsController(
      updateService: updateService,
      disableStartupUpdateCheck: disableStartupUpdateCheck,
    )..addListener(notifyListeners);
  }

  /// 相册等模块与主控制器共用同一个 OSS 客户端（凭证配置状态共享）。
  final OssClient ossClient;

  /// 会话与鉴权状态。
  late final SessionController sessionController;

  /// 工作区域状态（目录浏览、选择、缩略图、目录统计等）。
  late final WorkspaceController workspaceController;

  /// 传输队列（任务表、并发、暂停状态）。
  late final TransferQueue transferQueue;

  /// 传输任务操作（上传、下载、取消、重试等）。
  late final TransferController transferController;

  /// 分享导入状态。
  late final ShareImportController shareImportController;

  /// 移动编排。
  late final MoveController moveController;

  /// 删除与回收站编排。
  late final RecycleBinController recycleBinController;

  /// 别名编排。
  late final AliasController aliasController;

  /// 设置域状态（主题、自动检查更新、强制升级门禁）。
  late final SettingsController settingsController;

  /// 更新服务与设置页、强制升级拦截页共享同一实例（检查结果口径一致）。
  UpdateService get updateService => settingsController.updateService;

  /// 注入相册索引挂钩（上传增量更新、删除清理、还原恢复）。
  void setGalleryHooks(GalleryIndexHooks? hooks) {
    transferController.setGalleryHooks(hooks);
    moveController.setGalleryHooks(hooks);
    recycleBinController.setGalleryHooks(hooks);
  }

  /// 全局 Navigator Key，供传输队列与移动流程弹出冲突处置对话框。
  void setNavigatorKey(GlobalKey<NavigatorState>? key) {
    transferController.setNavigatorKey(key);
    moveController.setNavigatorKey(key);
  }

  /// 统一启动流程：偏好/传输恢复 → 会话恢复（由 SessionController
  /// 触发工作区据会话重置）。偏好读取失败不阻断会话恢复。
  Future<void> bootstrap() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      workspaceController.restorePreferences(preferences);
      await transferQueue.restore(preferences);
      settingsController.restorePreferences(preferences);
    } catch (_) {
      // 偏好读取失败不应阻断会话恢复。
    }
    await sessionController.bootstrap();
  }

  /// 会话清除前的跨域清理：取消运行中传输并清空队列暂停与冲突决策状态。
  void _handleBeforeSessionCleared() {
    for (final taskId in transferQueue.runningTaskIds) {
      transferQueue.markCanceled(taskId);
      unawaited(ossClient.cancelTransfer(taskId));
    }
    transferQueue.clearPendingTasks();
    transferQueue.clearPauseRequests();
    transferQueue.setQueuePaused(false);
    transferController.clearBatchConflictState();
  }

  /// 会话变更后的跨域复位：工作区域与分享导入状态分别委托各控制器。
  void _handleSessionChanged() {
    workspaceController.handleSessionChanged();
    shareImportController.handleSessionChanged();
  }

  @override
  void dispose() {
    transferQueue.markRunningCanceled();
    for (final taskId in transferQueue.runningTaskIds) {
      unawaited(ossClient.cancelTransfer(taskId));
    }
    workspaceController.dispose();
    recycleBinController.dispose();
    aliasController.dispose();
    moveController.dispose();
    shareImportController.dispose();
    transferController.dispose();
    transferQueue.dispose();
    sessionController.dispose();
    settingsController.dispose();
    super.dispose();
  }
}
