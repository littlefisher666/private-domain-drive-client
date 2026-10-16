import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_error.dart';
import '../../core/version/app_version.dart';
import '../../features/auth/application/session_controller.dart';
import '../../features/auth/domain/login_result.dart';
import '../../features/auth/domain/user_session.dart';
import '../../features/auth/infrastructure/saved_credentials_store.dart';
import '../../features/auth/infrastructure/session_repository.dart';
import '../../features/transfer/application/transfer_controller.dart';
import '../../features/transfer/application/transfer_queue.dart';
import '../../features/transfer/domain/transfer_enqueue.dart';
import '../../features/transfer/domain/transfer_task.dart';
import '../../features/transfer/infrastructure/upload_staging.dart';
import '../../features/preview/infrastructure/text_preview_loader.dart';
import '../../features/settings/application/update_service.dart';
import '../../features/settings/infrastructure/github_release_client.dart';
import '../../features/share_import/application/share_import_controller.dart';
import '../../features/share_import/domain/share_import_models.dart';
import '../../features/workspace/application/workspace_controller.dart';
import '../../features/workspace/domain/file_item.dart';
import '../../features/workspace/domain/directory_alias.dart';
import '../../features/workspace/domain/move_task_entry.dart';
import '../../features/workspace/domain/recycle_bin_entry.dart';
import '../../features/workspace/infrastructure/oss_client.dart';
import '../gallery_index_hooks.dart';
import '../path_utils.dart' as path_utils;
import '../transfer_keepalive.dart';

// 迁移期兼容：DirectorySizeState 改由 WorkspaceController 定义，
// 经本文件继续对外可见，避免调用方在拆除门面前感知类型移动。
export '../../features/workspace/application/workspace_controller.dart'
    show DirectorySizeState;

// 迁移期兼容：批量下载入队结果与上传冲突决策改由 transfer 域定义，
// 经本文件继续对外可见，避免调用方在拆除门面前感知类型移动。
export '../../features/transfer/domain/transfer_enqueue.dart'
    show BatchDownloadEnqueueResult, UploadConflictResolution;

// 迁移期兼容：分享导入模型改由 share_import 域定义，
// 经本文件继续对外可见，避免调用方在拆除门面前感知类型移动。
export '../../features/share_import/domain/share_import_models.dart'
    show ShareImportItem, ShareImportCompleteBatch, ShareImportBatchState;

class BatchDeletePreview {
  const BatchDeletePreview({
    required this.selectedCount,
    required this.directoryCount,
    required this.objectPaths,
    required this.items,
    this.topLevelPaths = const <String>{},
  });

  final int selectedCount;
  final int directoryCount;
  final Set<String> objectPaths;

  /// 用户勾选的顶层条目，逐项建立独立回收条目时用于对象归属分组。
  final List<FileItem> items;

  /// 用户勾选的顶层条目路径（不含目录展开结果），供统计缓存按目录修正。
  final Set<String> topLevelPaths;
  int get objectCount => objectPaths.length;
}

class BatchDeleteSummary {
  const BatchDeleteSummary({
    required this.deletedPaths,
    required this.failedPaths,
  });

  final List<String> deletedPaths;
  final List<String> failedPaths;
}

/// 目标路径已存在时的移动处置决策；不提供覆盖选项，避免破坏幂等重跑安全性。
enum MoveConflictResolution { skip, keepBoth }

class MoveProgress {
  const MoveProgress({
    required this.processed,
    required this.total,
    this.isUndo = false,
    this.isCounting = false,
  });

  final int processed;
  final int total;

  /// 撤销移动（反向搬回）与正向移动共用进度通道，文案据此区分。
  final bool isUndo;

  /// 仍在递归列举待迁移对象总数；为 true 时总数随每页列举结果递增，
  /// 列举完成后转为确定的「已处理/总数」。
  final bool isCounting;
}

/// 删除（移入回收站）进行中状态；total 为 0 表示仍在统计待删除对象。
class DeleteProgress {
  const DeleteProgress({required this.processed, required this.total});

  final int processed;
  final int total;
}

class MoveSummary {
  const MoveSummary({
    required this.movedCount,
    required this.failedKeys,
    this.sourceKeys = const <String>{},
    this.destinationKeys = const <String>{},
  });

  final int movedCount;
  final List<String> failedKeys;

  /// 本次搬运涉及的源侧与目标侧对象 key（含目录标记），供索引挂钩使用。
  final Set<String> sourceKeys;
  final Set<String> destinationKeys;

  bool get hasFailures => failedKeys.isNotEmpty;
}

/// 一次移动执行的单源计划：源前缀与其在目标侧的落点（重命名后）。
class _MovePlanPair {
  const _MovePlanPair({required this.source, required this.renameRoot});

  final String source;
  final String renameRoot;
}

/// 应用状态控制器。会话与权限来自已部署的 FC，不在生产路径伪造身份。
class AppController extends ChangeNotifier {
  AppController(
      {required SessionRepository sessionRepository,
      OssClient? ossClient,
      SavedCredentialsStore? savedCredentialsStore,
      UploadStaging? uploadStaging,
      TransferKeepaliveService? transferKeepalive,
      UpdateService? updateService,
      bool? disableStartupUpdateCheck})
      : _ossClient = ossClient ?? OssClient(),
        _updateService = updateService ??
            UpdateService(
              versionReader: PackageAppVersionReader(),
              releaseClient: GithubReleaseClient(),
            ),
        _disableStartupUpdateCheck = disableStartupUpdateCheck ??
            AppConstants.disableStartupUpdateCheck {
    _sessionController = SessionController(
      sessionRepository: sessionRepository,
      ossClient: _ossClient,
      savedCredentialsStore: savedCredentialsStore,
    )
      ..beforeSessionCleared = _handleBeforeSessionCleared
      ..onSessionChanged = _handleSessionChanged
      ..addListener(notifyListeners);
    _ossClient.onCredentialExpired = _sessionController.handleCredentialExpired;
    _workspaceController = WorkspaceController(
      sessionController: _sessionController,
      ossClient: _ossClient,
    )..addListener(notifyListeners);
    _transferQueue = TransferQueue(
      transferKeepalive: transferKeepalive ?? createTransferKeepaliveService(),
    );
    _transferController = TransferController(
      sessionController: _sessionController,
      workspaceController: _workspaceController,
      transferQueue: _transferQueue,
      ossClient: _ossClient,
      uploadStaging: uploadStaging,
    )..addListener(notifyListeners);
    _shareImportController = ShareImportController(
      sessionController: _sessionController,
      workspaceController: _workspaceController,
      transferController: _transferController,
    )..addListener(notifyListeners);
  }

  late final SessionController _sessionController;

  /// 工作区域状态由 [WorkspaceController] 持有；迁移期经门面继续暴露原 API。
  late final WorkspaceController _workspaceController;

  /// 传输队列状态由 [TransferQueue] 持有；迁移期经门面继续暴露原 API。
  late final TransferQueue _transferQueue;

  /// 传输任务操作由 [TransferController] 持有；迁移期经门面继续暴露原 API。
  late final TransferController _transferController;

  /// 分享导入状态由 [ShareImportController] 持有；迁移期经门面继续暴露原 API。
  late final ShareImportController _shareImportController;
  final OssClient _ossClient;

  /// 相册等模块与主控制器共用同一个 OSS 客户端（凭证配置状态共享）。
  OssClient get ossClient => _ossClient;

  /// 更新服务与设置页、强制升级拦截页共享同一实例（检查结果口径一致）。
  UpdateService get updateService => _updateService;
  final UpdateService _updateService;
  final bool _disableStartupUpdateCheck;
  GalleryIndexHooks? _galleryHooks;

  /// 注入相册索引挂钩（上传增量更新、删除清理、还原恢复）。
  void setGalleryHooks(GalleryIndexHooks? hooks) {
    _galleryHooks = hooks;
    _transferController.setGalleryHooks(hooks);
  }

  /// 全局 Navigator Key，供传输队列内弹出上传冲突处置对话框。
  GlobalKey<NavigatorState>? _navigatorKey;

  void setNavigatorKey(GlobalKey<NavigatorState>? key) {
    _navigatorKey = key;
    _transferController.setNavigatorKey(key);
  }

  static const rootPrefix = path_utils.rootPrefix;
  static const _movesRoot = '$rootPrefix.moves/';
  static const _trashRoot = '$rootPrefix.trash/';
  static const _themeModeKey = 'theme_mode';
  static const _autoCheckUpdatesKey = 'auto_check_updates';

  /// 选择与目录大小的细粒度监听器由 [WorkspaceController] 持有，
  /// 门面返回同一实例，界面监听行为不变。
  ValueNotifier<FileItem?> get selectedItemListenable =>
      _workspaceController.selectedItemListenable;

  ValueNotifier<Set<String>> get multiSelectedPathsListenable =>
      _workspaceController.multiSelectedPathsListenable;

  ValueNotifier<Map<String, DirectorySizeState>>
      get directorySizeStatesListenable =>
          _workspaceController.directorySizeStatesListenable;

  /// 任务表与并发/暂停通知器由 [TransferQueue] 持有，门面返回同一实例，
  /// 界面监听行为不变。
  ValueNotifier<List<TransferTask>> get tasksListenable =>
      _transferQueue.tasksListenable;

  /// 总并发数单独通知，避免传输进度刷新整个设置区域。
  ValueNotifier<int> get transferConcurrencyListenable =>
      _transferQueue.transferConcurrencyListenable;

  /// 队列级暂停开关：暂停时不再从等待队列拉起新任务，运行中任务收到
  /// 停止信号后回到等待队列，随 resumeAllTransfers 重新调度。
  ValueNotifier<bool> get transferQueuePausedListenable =>
      _transferQueue.transferQueuePausedListenable;

  bool get transferQueuePaused => _transferQueue.transferQueuePaused;

  /// 移动进行中状态（已处理/总对象数）；仅工作区条目区消费，避免整页重建。
  final ValueNotifier<MoveProgress?> moveStateListenable =
      ValueNotifier<MoveProgress?>(null);
  bool _isMoving = false;

  /// 删除（移入回收站）进行中状态；非阻塞横幅消费，删除期间不锁界面。
  final ValueNotifier<DeleteProgress?> deleteStateListenable =
      ValueNotifier<DeleteProgress?>(null);

  /// 会话状态由 [SessionController] 持有，此处保留只读引用供内部消费。
  UserSession? get _session => _sessionController.session;

  ThemeMode _themeMode = ThemeMode.light;
  bool _autoCheckUpdates = true;

  /// 强制升级门禁检查结果；非空表示当前版本低于最低支持版本、拦截生效。
  UpdateCheckResult? _forcedUpgradeResult;
  bool _forcedUpgradeChecking = false;

  SharedPreferences? _preferences;

  UserSession? get session => _sessionController.session;
  bool get isLoggedIn => _sessionController.isLoggedIn;
  String get currentPath => _workspaceController.currentPath;

  /// 当前会话的工作区根目录，供目录选择器等需要全树导航的场景使用。
  String get workspaceRoot => _workspaceController.workspaceRoot;

  String _recycleBinPath = rootPrefix;

  String get recycleBinPath => _recycleBinPath;

  void setRecycleBinPath(String path) {
    _recycleBinPath = _normalizeDir(path);
    notifyListeners();
  }

  /// 回收站内返回上一级：处于某个条目根层时回到回收站根层。
  String recycleBinUpPath() {
    final current = _normalizeDir(_recycleBinPath);
    final root = _normalizeDir(rootPrefix);
    if (current == root) return root;
    if (current.startsWith(_trashRoot)) {
      final rest = current.substring(_trashRoot.length);
      final segments = rest.split('/').where((segment) => segment.isNotEmpty);
      if (segments.length <= 1) return root;
    }
    return parentPath(current);
  }

  /// 将 OSS 内部对象键转换为用户可见的相对路径。
  String displayPath(String path) => _workspaceController.displayPath(path);

  /// 工作区标题：经别名进入且仍在别名根层级时显示别名名称。
  String get currentTitle => _workspaceController.currentTitle;

  /// 后退目标目录；处于别名根层级时返回进入前的挂载层级，已在根目录返回 null。
  String? backNavigationPath() => _workspaceController.backNavigationPath();

  /// 当前已加载的别名条目，供名称冲突校验与目录选择器复用。
  List<DirectoryAlias> get directoryAliases =>
      _workspaceController.directoryAliases;

  BrowseMode get browseMode => _workspaceController.browseMode;
  ThumbnailSize get thumbnailSize => _workspaceController.thumbnailSize;
  FileSortOption get fileSortOption => _workspaceController.fileSortOption;
  List<TransferTask> get tasks => _transferQueue.tasks;
  int get transferConcurrency => _transferQueue.transferConcurrency;
  int get runningTransferCount => _transferQueue.runningTransferCount;
  int get pendingTransferCount => _transferQueue.pendingTransferCount;
  bool get isMoving => _isMoving;

  List<ShareImportItem> get pendingShareItems =>
      _shareImportController.pendingShareItems;
  String get shareTargetPath => _shareImportController.shareTargetPath;

  /// 当前渐进接收中的分享批次进度；批次完成后保留 finished 状态供
  /// 弹窗展示失败计数，直到确认/取消/新批次到来时清除。
  ShareImportBatchState? get activeShareBatch =>
      _shareImportController.activeShareBatch;

  /// 待弹目录选择弹窗的批次 id；防重入签名以批次 id 为准。
  List<String> get pendingShareBatchIds =>
      _shareImportController.pendingShareBatchIds;
  FileItem? get selectedItem => _workspaceController.selectedItem;
  bool get isMultiSelectionMode => _workspaceController.isMultiSelectionMode;
  int get multiSelectedCount => _workspaceController.multiSelectedCount;
  Set<String> get multiSelectedPaths => _workspaceController.multiSelectedPaths;
  bool get bootstrapped => _sessionController.bootstrapped;
  ThemeMode get themeMode => _themeMode;

  /// 是否在启动时自动检查更新（仅 macOS Sparkle 路径消费）。
  bool get autoCheckUpdates => _autoCheckUpdates;

  /// 更新启动自动检查偏好；写入失败时保留本次会话的选择。
  Future<void> setAutoCheckUpdates(bool value) async {
    if (_autoCheckUpdates == value) {
      return;
    }
    _autoCheckUpdates = value;
    notifyListeners();
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setBool(_autoCheckUpdatesKey, value);
    } catch (_) {
      // 偏好写入失败时仍保留本次会话的选择。
    }
  }

  /// 强制升级拦截是否生效；生效时应用外壳以强制升级页替换整棵界面。
  bool get forcedUpgradeActive => _forcedUpgradeResult != null;

  /// 拦截生效时的检查结果（当前版本、最低支持版本与可用升级资产）。
  UpdateCheckResult? get forcedUpgradeResult => _forcedUpgradeResult;

  /// 启动静默检查与拦截页「重试」共用的门禁检查：成功后按结果更新门禁
  /// 状态；失败（离线、超时、响应异常）静默放行且不缓存结论，下一次启动
  /// 或重试时重新检查。不受 macOS「启动时自动检查更新」开关约束，
  /// 仅受编译期调试开关 `DISABLE_STARTUP_UPDATE_CHECK` 约束。
  Future<void> checkForcedUpgradeGate() async {
    if (_disableStartupUpdateCheck || _forcedUpgradeChecking) return;
    _forcedUpgradeChecking = true;
    try {
      final result = await _updateService.checkLatest();
      final forced = result.requiresForcedUpgrade;
      _forcedUpgradeResult = forced ? result : null;
      debugPrint(forced
          ? '[强制升级] 当前版本 ${result.currentVersion} 低于最低支持版本 '
              '${result.minSupportedVersion}，进入拦截'
          : '[强制升级] 门禁检查通过，当前版本 ${result.currentVersion}');
    } catch (error, stackTrace) {
      debugPrint('[强制升级] 门禁检查失败，放行：$error');
      debugPrintStack(stackTrace: stackTrace, label: '[强制升级] 门禁检查异常堆栈');
      // 失败不改变门禁状态：启动阶段保持放行，拦截期间保持拦截。
      return;
    } finally {
      _forcedUpgradeChecking = false;
      notifyListeners();
    }
  }

  int get treeRevision => _workspaceController.treeRevision;
  Capabilities get capabilities =>
      _session?.capabilities ?? const Capabilities.member();

  Future<void> bootstrap() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _preferences = preferences;
      _workspaceController.restorePreferences(preferences);
      await _transferQueue.restore(preferences);
      _restoreThemeMode(preferences);
      _restoreAutoCheckUpdates(preferences);
    } catch (_) {
      // 偏好读取失败不应阻断会话恢复。
    }
    await _sessionController.bootstrap();
  }

  /// 更新显示模式；偏好会在下次启动时恢复。
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) {
      return;
    }
    _themeMode = mode;
    notifyListeners();
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setString(_themeModeKey, mode.name);
    } catch (_) {
      // 偏好写入失败时仍保留本次会话的选择。
    }
  }

  Future<LoginResult> login({
    required String account,
    required String password,
  }) =>
      _sessionController.login(account: account, password: password);

  /// 供登录页预填最近一次成功登录的用户名与密码。
  Future<SavedCredentials?> readSavedCredentials() =>
      _sessionController.readSavedCredentials();

  Future<void> logout() => _sessionController.logout();

  Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) =>
      _sessionController.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );

  /// 校验当前会话可用。访问密钥为登录下发的长期密钥，
  /// 无需刷新；失效时由 [SessionController.handleCredentialExpired] 引导重新登录。
  Future<void> ensureSessionReady() => _sessionController.ensureSessionReady();

  UserSession _requireSession() => _sessionController.requireSession();

  /// 会话清除前的跨域清理：取消运行中传输并清空队列暂停与冲突决策状态。
  void _handleBeforeSessionCleared() {
    for (final taskId in _transferQueue.runningTaskIds) {
      _transferQueue.markCanceled(taskId);
      unawaited(_ossClient.cancelTransfer(taskId));
    }
    _transferQueue.clearPendingTasks();
    _transferQueue.clearPauseRequests();
    _transferQueue.setQueuePaused(false);
    _transferController.clearBatchConflictState();
  }

  /// 会话变更后的跨域复位：工作区域与分享导入状态分别委托各控制器。
  void _handleSessionChanged() {
    _workspaceController.handleSessionChanged();
    _shareImportController.handleSessionChanged();
  }

  Future<List<FileItem>> listDirectory([String? path]) =>
      _workspaceController.listDirectory(path);

  /// 目录选择器专用：仅前缀列举子目录（单次请求），不做子内容统计。
  Future<List<FileItem>> listSubdirectories(String path) =>
      _workspaceController.listSubdirectories(path);

  /// 读取单个目录统计的缓存命中值；未命中返回 null。
  Future<DirectorySummary?> cachedDirectorySummary(String path) =>
      _workspaceController.cachedDirectorySummary(path);

  /// 批量读取目录统计缓存命中值，key 为目录路径。
  Future<Map<String, DirectorySummary>> cachedDirectorySummaries(
          Iterable<String> paths) =>
      _workspaceController.cachedDirectorySummaries(paths);

  /// 后台受限并发统计子文件夹并逐个回调，不阻塞调用方。
  Future<void> refreshDirectorySummaries(
    Iterable<String> paths, {
    required void Function(String path, DirectorySummary summary) onResult,
  }) =>
      _workspaceController.refreshDirectorySummaries(paths, onResult: onResult);

  void noteDirectoryFilesAdded(String dir, int count, DateTime at) =>
      _workspaceController.noteDirectoryFilesAdded(dir, count, at);

  void noteDirectoryFilesRemoved(String dir, int count) =>
      _workspaceController.noteDirectoryFilesRemoved(dir, count);

  void invalidateDirectorySummary(String dir) =>
      _workspaceController.invalidateDirectorySummary(dir);

  /// 目录选择器使用：与 [listSubdirectories] 一致，但按层级合并挂载于
  /// [path] 的别名条目（path 指向目标目录），使别名可作为移动/挂载目标。
  Future<List<FileItem>> listPickerDirectories(String path) =>
      _workspaceController.listPickerDirectories(path);

  Future<List<int>> loadThumbnail(FileItem item) =>
      _workspaceController.loadThumbnail(item);

  Future<List<int>> loadImagePreview(FileItem item) =>
      _workspaceController.loadImagePreview(item);

  String get thumbnailCacheNamespace =>
      _workspaceController.thumbnailCacheNamespace;

  /// 加载 PDF 文档本地文件：缓存命中直接返回；未命中走预签名 URL
  /// 流式下载落盘后写入文档缓存。失败时抛出异常由界面展示重试。
  Future<File> loadPdfDocument(FileItem item) =>
      _workspaceController.loadPdfDocument(item);

  /// 创建文本预览分段加载器（编码与 20MB 上限策略内聚在加载器中）。
  TextPreviewLoader createTextPreviewLoader(FileItem item) =>
      _workspaceController.createTextPreviewLoader(item);

  /// 生成音频等对象的预签名 URL，用于 media_kit 流式播放。
  Future<String> presignMediaUrl(FileItem item) =>
      _workspaceController.presignMediaUrl(item);

  void setCurrentPath(String path) => _workspaceController.setCurrentPath(path);

  /// 进入虚拟目录别名：此后浏览、上传、下载、删除、移动等操作均作用于
  /// 别名的真实目标前缀。目标已失效（前缀下无任何对象）时抛出明确错误，
  /// 不展示空目录成功态。
  Future<void> openAlias(FileItem alias) async {
    if (!alias.isAlias || alias.aliasId == null) {
      throw StateError('条目不是目录别名');
    }
    final session = _requireSession();
    await ensureSessionReady();
    final target = _normalizeDir(alias.path);
    if (!await _ossClient.directoryExists(target, session)) {
      throw AppError(
        '目标目录不存在，链接可能已失效',
        code: 'ALIAS_TARGET_MISSING',
      );
    }
    final origin = _normalizeDir(currentPath);
    final root = _normalizeDir(workspaceRoot);
    // 后退返回进入别名前所在的层级，即其挂载层级。
    _workspaceController.enterAliasTarget(
      targetPrefix: target,
      aliasName: alias.name,
      returnPath: origin.startsWith(root) && origin != target ? origin : null,
    );
  }

  /// 为真实文件夹条目创建指向它的目录别名，挂载到 [parentPrefix] 层级。
  Future<void> createAlias(
    FileItem targetFolder,
    String name, {
    required String parentPrefix,
  }) async {
    _ensureUploadCapability();
    final session = _requireSession();
    await ensureSessionReady();
    final target = _normalizeDir(targetFolder.path);
    final root = _normalizeDir(workspaceRoot);
    final parent = _normalizeDir(parentPrefix);
    if (target == root) {
      throw StateError('不能为根目录创建链接');
    }
    if (!parent.startsWith(root)) {
      throw StateError('挂载位置不在网盘范围内');
    }
    final aliasName = name.trim();
    await _validateAliasName(
      aliasName,
      session,
      parentPrefix: parent,
    );
    if (!await _ossClient.directoryExists(target, session)) {
      throw AppError('目标目录不存在，无法创建链接', code: 'ALIAS_TARGET_MISSING');
    }
    final alias = DirectoryAlias.create(
      name: aliasName,
      targetPrefix: target,
      parentPrefix: parent,
      createdBy: session.displayName.isNotEmpty == true
          ? session.displayName
          : session.account,
    );
    await _workspaceController.persistAliasTable(
      session,
      (table) => table.copyWith(aliases: [...table.aliases, alias]),
    );
    _workspaceController.bumpTreeRevision();
    _workspaceController.clearDirectorySizeCache();
    notifyListeners();
  }

  /// 删除链接：仅从别名表移除条目，不影响目标目录内容。
  Future<void> deleteAlias(FileItem aliasItem) async {
    _ensureDeleteCapability();
    final id = aliasItem.aliasId;
    if (!aliasItem.isAlias || id == null) {
      throw StateError('条目不是目录别名');
    }
    final session = _requireSession();
    await ensureSessionReady();
    await _workspaceController.persistAliasTable(
      session,
      (table) => table.copyWith(
        aliases:
            table.aliases.where((alias) => alias.id != id).toList(),
      ),
    );
    _workspaceController.bumpTreeRevision();
    notifyListeners();
  }

  /// 重命名链接：仅修改别名表中的展示名称。
  Future<void> renameAlias(FileItem aliasItem, String newName) async {
    _ensureUploadCapability();
    final id = aliasItem.aliasId;
    if (!aliasItem.isAlias || id == null) {
      throw StateError('条目不是目录别名');
    }
    final session = _requireSession();
    await ensureSessionReady();
    final existing = _workspaceController.aliasTable.byId(id);
    if (existing == null) {
      throw StateError('别名条目不存在');
    }
    final aliasName = newName.trim();
    await _validateAliasName(
      aliasName,
      session,
      parentPrefix: existing.parentPrefix,
      excludeAliasId: id,
    );
    await _workspaceController.persistAliasTable(
      session,
      (table) => table.copyWith(
        aliases: <DirectoryAlias>[
          for (final alias in table.aliases)
            if (alias.id == id) alias.copyWith(name: aliasName) else alias,
        ],
      ),
    );
    _workspaceController.renameActiveAlias(aliasItem.name, aliasName);
    _workspaceController.bumpTreeRevision();
    notifyListeners();
  }

  /// 校验别名名称：非空、不以点开头、不含 `/`，且不与挂载层级
  /// [parentPrefix] 现有真实条目或同级别名重名（忽略大小写）。
  Future<void> _validateAliasName(
    String name,
    UserSession session, {
    required String parentPrefix,
    String? excludeAliasId,
  }) async {
    if (name.isEmpty) {
      throw StateError('名称不能为空');
    }
    if (name.startsWith('.')) {
      throw StateError('名称不能以点开头');
    }
    if (name.contains('/')) {
      throw StateError('名称不能包含 /');
    }
    final level = _normalizeDir(parentPrefix);
    final levelNames = await _ossClient.listEntryNames(level, session);
    final lowerName = name.toLowerCase();
    if (levelNames.any((entry) => entry.toLowerCase() == lowerName)) {
      throw StateError('该目录层级已存在同名条目');
    }
    for (final alias in _workspaceController.aliasTable.aliases) {
      if (alias.id == excludeAliasId) continue;
      if (_normalizeDir(alias.parentPrefix) == level &&
          alias.name.toLowerCase() == lowerName) {
        throw StateError('该目录层级已存在同名链接');
      }
    }
  }

  void setBrowseMode(BrowseMode mode) =>
      _workspaceController.setBrowseMode(mode);

  Future<void> setThumbnailSize(ThumbnailSize size) =>
      _workspaceController.setThumbnailSize(size);

  Future<void> setFileSortOption(FileSortOption option) =>
      _workspaceController.setFileSortOption(option);

  void _restoreThemeMode(SharedPreferences preferences) {
    _themeMode = switch (preferences.getString(_themeModeKey)) {
      'dark' => ThemeMode.dark,
      _ => ThemeMode.light,
    };
  }

  void _restoreAutoCheckUpdates(SharedPreferences preferences) {
    _autoCheckUpdates = preferences.getBool(_autoCheckUpdatesKey) ?? true;
  }

  void selectItem(FileItem? item) => _workspaceController.selectItem(item);

  void enterMultiSelection([FileItem? initial]) =>
      _workspaceController.enterMultiSelection(initial);

  void toggleMultiSelection(FileItem item,
          {List<FileItem>? visibleItems, bool range = false}) =>
      _workspaceController.toggleMultiSelection(item,
          visibleItems: visibleItems, range: range);

  void selectAllItems(Iterable<FileItem> items) =>
      _workspaceController.selectAllItems(items);

  /// 用于桌面端拖拽框选，以一次状态更新替换当前可见项的选择结果。
  void replaceMultiSelection(Iterable<String> paths) =>
      _workspaceController.replaceMultiSelection(paths);

  void clearMultiSelection() => _workspaceController.clearMultiSelection();

  /// 在当前目录的可见排序中移动当前项，不改变批量勾选状态。
  bool moveSelection(
    List<FileItem> visibleItems, {
    required int offset,
  }) =>
      _workspaceController.moveSelection(visibleItems, offset: offset);

  String parentPath(String path) => path_utils.parentPathOf(path);

  Future<void> createFolder(String name, {String? targetPath}) =>
      _workspaceController.createFolder(name, targetPath: targetPath);

  Future<void> renameItem(FileItem item, String newName) =>
      _workspaceController.renameItem(item, newName);

  Future<void> deleteItem(FileItem item) async {
    _ensureDeleteCapability();
    await ensureSessionReady();
    final session = _requireSession();
    // 大目录先列全量 key，耗时较长；先置进度让横幅立即可见。
    deleteStateListenable.value = const DeleteProgress(processed: 0, total: 0);
    final paths = <String>{item.path};
    if (item.isDirectory) {
      paths.addAll(await _ossClient.listAllObjectKeys(item.path, session));
    }
    final result = await _moveToRecycleBin(
      _planRecycleBinItems(<FileItem>[item], paths),
      session: session,
    );
    if (result.failedPaths.isNotEmpty) {
      throw StateError('有 ${result.failedPaths.length} 个对象未能移入回收站');
    }
    if (item.isDirectory) {
      final deletedPath = _normalizeDir(item.path);
      _workspaceController.removeBrowsedDirectoriesWhere(
        (path) => path == deletedPath || path.startsWith(deletedPath),
      );
      if (currentPath.startsWith(deletedPath)) {
        _workspaceController.replaceCurrentPath(parentPath(deletedPath));
      }
    }
    _workspaceController.bumpTreeRevision();
    _workspaceController.clearDirectorySizeCache();
    _workspaceController.noteTopLevelChanges(
      <String>[item.path],
      const <String>{},
      delta: -1,
    );

    if (selectedItem?.path == item.path) {
      _workspaceController.clearSelectedItem();
    }
    unawaited(_galleryHooks?.onObjectsDeleted(paths));
    notifyListeners();
  }

  Future<BatchDeletePreview> prepareBatchDelete(
    Iterable<FileItem> items,
  ) async {
    _ensureDeleteCapability();
    final selected = items.toList(growable: false);
    final paths = <String>{};
    await ensureSessionReady();
    final session = _requireSession();
    for (final item in selected) {
      _workspaceController.ensureWithinRoot(item.path);
      paths.add(item.path);
      if (item.isDirectory) {
        paths.addAll(await _ossClient.listAllObjectKeys(item.path, session));
      }
    }
    return BatchDeletePreview(
      selectedCount: selected.length,
      directoryCount: selected.where((item) => item.isDirectory).length,
      objectPaths: paths,
      topLevelPaths: selected.map((item) => item.path).toSet(),
      items: selected,
    );
  }

  Future<BatchDeleteSummary> deleteBatch(
    BatchDeletePreview preview,
  ) async {
    _ensureDeleteCapability();
    await ensureSessionReady();
    final result = await _moveToRecycleBin(
      _planRecycleBinItems(preview.items, preview.objectPaths),
      session: _requireSession(),
    );
    final deleted = result.deletedPaths;
    final failed = result.failedPaths;
    if (deleted.isNotEmpty) {
      _workspaceController.clearDirectorySizeCache();
      _workspaceController.removeBrowsedDirectoriesWhere(
          (path) => deleted.contains(path));
      if (deleted.any((path) => currentPath.startsWith(_normalizeDir(path)))) {
        _workspaceController.replaceCurrentPath(parentPath(currentPath));
      }
      _workspaceController.bumpTreeRevision();
      _workspaceController.clearSelectedItem();
      _workspaceController.noteTopLevelChanges(
        preview.topLevelPaths,
        failed.toSet(),
        delta: -1,
      );
      unawaited(_galleryHooks?.onObjectsDeleted(deleted.toSet()));
      notifyListeners();
    }
    return BatchDeleteSummary(deletedPaths: deleted, failedPaths: failed);
  }

  /// 按用户勾选的顶层条目把对象路径归组，逐条目建立独立回收条目。
  ///
  /// 目录条目认领其前缀下的对象；文件条目只认领自身路径。先按路径
  /// 深度排序保证父目录先认领；未被任何条目认领的对象（如嵌套选中
  /// 被父目录覆盖）不重复归属。条目没有任何对象时跳过。
  List<({FileItem item, List<String> objectPaths})> _planRecycleBinItems(
    List<FileItem> items,
    Set<String> objectPaths,
  ) {
    final sources = objectPaths
        .where((path) => path.startsWith(rootPrefix))
        .toSet();
    final sorted = items.toList(growable: false)
      ..sort((a, b) {
        final byLength = a.path.length.compareTo(b.path.length);
        return byLength != 0 ? byLength : a.path.compareTo(b.path);
      });
    final claimed = <String>{};
    final planned = <({FileItem item, List<String> objectPaths})>[];
    for (final item in sorted) {
      final dir = item.isDirectory ? _normalizeDir(item.path) : null;
      final owned = <String>[
        for (final path in sources)
          if (!claimed.contains(path) &&
              (dir != null
                  ? path == item.path || path.startsWith(dir)
                  : path == item.path))
            path,
      ];
      if (owned.isEmpty) continue;
      claimed.addAll(owned);
      planned.add((item: item, objectPaths: owned));
    }
    return planned;
  }

  Future<BatchDeleteSummary> _moveToRecycleBin(
    List<({FileItem item, List<String> objectPaths})> planned, {
    required UserSession session,
  }) async {
    final total = planned.fold<int>(0, (sum, plan) => sum + plan.objectPaths.length);
    deleteStateListenable.value = DeleteProgress(processed: 0, total: total);
    final copiedAll = <String, String>{};
    final failed = <String>[];
    try {
      final takenNames = await _recycleBinEntryNames(session);
      for (final plan in planned) {
        final id =
            '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
        final entryRoot = '$_trashRoot$id/';
        final copied = <String, String>{};
        // 与移动操作一致：小批次并发 copy，避免逐对象串行耗时过长。
        var done = deleteStateListenable.value?.processed ?? 0;
        const concurrency = 6;
        final sources = plan.objectPaths;
        for (var start = 0; start < sources.length; start += concurrency) {
          final end = min(start + concurrency, sources.length);
          await Future.wait(sources.sublist(start, end).map((source) async {
            final target =
                '$entryRoot' 'payload/${source.substring(rootPrefix.length)}';
            try {
              await _ossClient.copy(source, target, session);
              copied[source] = target;
            } catch (_) {
              failed.add(source);
            }
            done++;
            deleteStateListenable.value =
                DeleteProgress(processed: done, total: total);
          }));
        }
        if (copied.isNotEmpty) {
          final name = _uniqueRecycleBinName(
            plan.item.name,
            plan.item.isDirectory,
            takenNames,
          );
          takenNames.add(name);
          final entry = RecycleBinEntry(
            id: id,
            name: name,
            originalPath: plan.item.path,
            isDirectory: plan.item.isDirectory,
            deletedAt: DateTime.now(),
            objects: copied,
          );
          await _ossClient.uploadText(
              '$entryRoot' 'manifest.json', entry.encode(), session);
        }
        copiedAll.addAll(copied);
      }
      final deleted = <String>[];
      for (final keys in _batches(copiedAll.keys)) {
        try {
          final result = await _ossClient.deleteMany(keys, session);
          deleted.addAll(result.deletedPaths);
          failed.addAll(result.failedPaths);
        } catch (_) {
          failed.addAll(keys);
        }
      }
      return BatchDeleteSummary(deletedPaths: deleted, failedPaths: failed);
    } finally {
      deleteStateListenable.value = null;
    }
  }

  /// 已占用的回收条目展示名，用于重名去重。
  Future<Set<String>> _recycleBinEntryNames(UserSession session) async {
    try {
      return {
        for (final entry in await listRecycleBin()) entry.name,
      };
    } catch (_) {
      // 列举失败时退化为不去重，避免阻塞删除主流程。
      return <String>{};
    }
  }

  /// 为回收条目生成展示名：与现有条目重名时追加 `_yyyyMMdd_HHmmss`
  /// 时间戳（文件插在扩展名前，目录在末尾），仍冲突时再加序号。
  String _uniqueRecycleBinName(
    String rawName,
    bool isDirectory,
    Set<String> taken,
  ) {
    if (!taken.contains(rawName)) return rawName;
    final timestamp = _recycleBinTimestamp(DateTime.now());
    String stem;
    String extension;
    if (isDirectory) {
      stem = rawName;
      extension = '';
    } else {
      final dot = rawName.lastIndexOf('.');
      stem = dot > 0 ? rawName.substring(0, dot) : rawName;
      extension = dot > 0 ? rawName.substring(dot) : '';
    }
    var candidate = '$stem$extension';
    if (!taken.contains(candidate)) return candidate;
    var sequence = 1;
    do {
      sequence++;
      candidate = '${stem}_$timestamp${sequence > 2 ? '_$sequence' : ''}$extension';
    } while (taken.contains(candidate));
    return candidate;
  }

  String _recycleBinTimestamp(DateTime time) {
    final mm = time.month.toString().padLeft(2, '0');
    final dd = time.day.toString().padLeft(2, '0');
    final hh = time.hour.toString().padLeft(2, '0');
    final mi = time.minute.toString().padLeft(2, '0');
    final ss = time.second.toString().padLeft(2, '0');
    return '${time.year}$mm$dd' '_$hh$mi$ss';
  }

  Iterable<List<String>> _batches(Iterable<String> keys) sync* {
    final values = keys.toList(growable: false);
    for (var offset = 0; offset < values.length; offset += 1000) {
      yield values.sublist(offset, min(offset + 1000, values.length));
    }
  }

  Future<List<RecycleBinEntry>> listRecycleBin() async {
    await ensureSessionReady();
    final session = _requireSession();
    final prefixes = await _ossClient.listPrefixes(_trashRoot, session);
    final entries = <RecycleBinEntry>[];
    for (final prefix in prefixes) {
      try {
        entries.add(RecycleBinEntry.decode(
          utf8.decode(
              await _ossClient.download('$prefix' 'manifest.json', session)),
        ));
      } catch (_) {
        // 未完成的回收批次没有 manifest，等待生命周期规则自动清理。
      }
    }
    entries.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return entries;
  }

  Future<void> restoreRecycleBinEntry(RecycleBinEntry entry) async {
    await ensureSessionReady();
    final session = _requireSession();
    final restored = <String, String>{};
    for (final item in entry.objects.entries) {
      final destination = await _availableRestorePath(item.key, session);
      await _ossClient.copy(item.value, destination, session);
      restored[item.value] = destination;
    }
    for (final keys in _batches(<String>[
      ...restored.keys,
      '$_trashRoot${entry.id}/manifest.json'
    ])) {
      await _ossClient.deleteMany(keys, session);
    }
    _workspaceController.bumpTreeRevision();
    _workspaceController.clearDirectorySizeCache();
    // 还原目标位置可能带改名后缀，逐个失效还原目录，由校准重建。
    final restoredDirs = <String>{
      for (final destination in restored.values)
        _normalizeDir(parentPath(destination)),
    };
    for (final dir in restoredDirs) {
      _workspaceController.invalidateDirectorySummary(dir);
      _workspaceController.calibrateDirectorySummary(dir);
    }
    unawaited(_galleryHooks?.onObjectsRestored(restored.values.toSet()));
    notifyListeners();
  }

  /// 立即删除一个回收条目；对象清单已覆盖条目的全部 payload 对象。
  Future<void> purgeRecycleBinEntry(RecycleBinEntry entry) async {
    await ensureSessionReady();
    final session = _requireSession();
    final failed = <String>[];
    for (final keys in _batches(<String>[
      ...entry.objects.values,
      '$_trashRoot${entry.id}/manifest.json'
    ])) {
      final result = await _ossClient.deleteMany(keys, session);
      failed.addAll(result.failedPaths);
    }
    if (failed.isNotEmpty) {
      throw AppError('有 ${failed.length} 个对象删除失败，请稍后重试',
          code: 'OSS_DELETE_FAILED');
    }
    // 清空回收批次不影响可浏览目录的计数，仅失效原目录由校准重建。
    final originalDir = _normalizeDir(parentPath(entry.originalPath));
    _workspaceController.invalidateDirectorySummary(originalDir);
    _workspaceController.calibrateDirectorySummary(originalDir);
    notifyListeners();
  }

  Future<String> _availableRestorePath(
      String desired, UserSession session) async {
    if (!await _ossClient.objectExists(desired, session)) return desired;
    final directory = parentPath(desired);
    final rawName = desired.substring(directory.length);
    final isDirectory = rawName.endsWith('/');
    final name =
        isDirectory ? rawName.substring(0, rawName.length - 1) : rawName;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var number = 0;; number++) {
      final suffix = number == 0 ? '（已还原）' : '（已还原 $number）';
      final candidate =
          '$directory$stem$suffix$extension${isDirectory ? '/' : ''}';
      if (!await _ossClient.objectExists(candidate, session)) return candidate;
    }
  }

  /// 重试部分失败的对象：按失败路径重建顶层条目（仅对象级信息，
  /// 展示名取路径末段），保持逐项独立回收条目的口径。
  Future<BatchDeleteSummary> retryBatchDelete(Iterable<String> failedPaths) {
    final paths = failedPaths.toSet();
    final items = <FileItem>[
      for (final path in paths)
        FileItem(
          path: path,
          name: path.endsWith('/')
              ? path.substring(0, path.length - 1).split('/').last
              : path.split('/').last,
          isDirectory: path.endsWith('/'),
        ),
    ];
    return deleteBatch(BatchDeletePreview(
      selectedCount: items.length,
      directoryCount: items.where((item) => item.isDirectory).length,
      objectPaths: paths,
      items: items,
    ));
  }

  /// 发起移动：源去重 → 目标合法性校验 → 冲突检测与处置 → 写 manifest → 执行。
  /// 返回 null 表示用户在冲突处置或互斥检查后取消，未产生任何搬运。
  Future<MoveSummary?> moveItems(
    List<FileItem> items,
    String targetDir,
  ) async {
    if (_isMoving) {
      throw StateError('已有移动任务进行中，请等待完成');
    }
    _ensureUploadCapability();
    _ensureDeleteCapability();
    final targetPrefix = _normalizeDir(targetDir);
    await ensureSessionReady();
    final session = _requireSession();

    final sources = _dedupeMoveSources(items);
    if (sources.isEmpty) {
      throw StateError('没有可移动的条目');
    }
    _validateMoveTargets(sources, targetPrefix);

    final plan = await _planMove(sources, targetPrefix, session);
    if (plan == null) {
      return null;
    }
    final summary = await _executeMovePlan(
      plan: plan,
      targetPrefix: targetPrefix,
      session: session,
    );
    _refreshAfterMove(
      sources.map((item) => item.path),
      plan.map((pair) => pair.renameRoot),
      summary,
    );
    unawaited(_galleryHooks?.onObjectsDeleted(summary.sourceKeys));
    unawaited(_galleryHooks?.onObjectsRestored(summary.destinationKeys));
    return summary;
  }

  /// 对包含父文件夹与其子项的选择去重：父前缀已覆盖子路径。
  List<FileItem> _dedupeMoveSources(List<FileItem> items) {
    final sorted = items.toList(growable: false)
      ..sort((a, b) => a.path.length.compareTo(b.path.length));
    final sources = <FileItem>[];
    for (final item in sorted) {
      _workspaceController.ensureWithinRoot(item.path);
      if (sources.any((source) =>
          item.path.startsWith(_normalizeDir(source.path)) ||
          item.path == source.path)) {
        continue;
      }
      sources.add(item);
    }
    return sources;
  }

  /// 目标不得为任何源目录自身或其子目录，也不得与全部源的所在目录相同。
  void _validateMoveTargets(List<FileItem> sources, String targetPrefix) {
    for (final item in sources) {
      if (!item.isDirectory) continue;
      final dirPrefix = _normalizeDir(item.path);
      if (targetPrefix == dirPrefix || targetPrefix.startsWith(dirPrefix)) {
        throw StateError('目标目录不能是「${item.name}」自身或其子目录');
      }
    }
    final sameAsSourceParent = sources
        .every((item) => _normalizeDir(parentPath(item.path)) == targetPrefix);
    if (sameAsSourceParent) {
      throw StateError('目标目录与源所在目录相同，无需移动');
    }
  }

  /// 逐条目检测目标路径冲突并生成执行计划；存在冲突时向用户请求处置。
  Future<List<_MovePlanPair>?> _planMove(
    List<FileItem> sources,
    String targetPrefix,
    UserSession session,
  ) async {
    final desiredPaths = <String>[
      for (final item in sources)
        '$targetPrefix${item.name}${item.isDirectory ? '/' : ''}',
    ];
    final exists = await Future.wait(desiredPaths
        .map((desired) => _ossClient.objectExists(desired, session)));
    final conflicts = <FileItem>[
      for (var index = 0; index < sources.length; index++)
        if (exists[index]) sources[index],
    ];
    var resolution = MoveConflictResolution.keepBoth;
    if (conflicts.isNotEmpty) {
      final decision =
          await _showMoveConflictDialog(conflicts.map((item) => item.name)
              .toList(growable: false));
      if (decision == null) {
        return null;
      }
      resolution = decision;
    }
    final plan = <_MovePlanPair>[];
    for (final item in sources) {
      if (conflicts.contains(item) && resolution == MoveConflictResolution.skip) {
        continue;
      }
      var name = item.name;
      if (conflicts.contains(item)) {
        name = (await _nonConflictingObjectPath(
                '$targetPrefix$name${item.isDirectory ? '/' : ''}', session))
            .substring(targetPrefix.length)
            .replaceFirst(RegExp(r'/$'), '');
      }
      plan.add(_MovePlanPair(
        source: item.path,
        renameRoot: '$targetPrefix$name${item.isDirectory ? '/' : ''}',
      ));
    }
    return plan;
  }

  /// 写 manifest 后逐对象 copy→delete 执行计划；全部成功时删除 manifest，
  /// 存在失败时保留 manifest 供冷启动继续或撤销。
  Future<MoveSummary> _executeMovePlan({
    required List<_MovePlanPair> plan,
    required String targetPrefix,
    required UserSession session,
    String? manifestId,
  }) async {
    _isMoving = true;
    notifyListeners();
    final id = manifestId ??
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final manifestKey = '$_movesRoot$id/manifest.json';
    try {
      final entry = MoveTaskEntry(
        id: id,
        sourcePrefixes: plan.map((pair) => pair.source).toList(growable: false),
        destinations: plan.map((pair) => pair.renameRoot).toList(growable: false),
        targetPrefix: targetPrefix,
        createdAt: DateTime.now(),
      );
      await _ossClient.uploadText(manifestKey, entry.encode(), session);
      final summary = await _runMovePlan(plan, session);
      if (!summary.hasFailures) {
        try {
          await _ossClient.delete(manifestKey, session);
        } catch (_) {
          // manifest 删除失败仅残留一个可再次处理的任务，不影响结果。
        }
      }
      return summary;
    } finally {
      _isMoving = false;
      moveStateListenable.value = null;
      notifyListeners();
    }
  }

  Future<MoveSummary> _runMovePlan(
    List<_MovePlanPair> plan,
    UserSession session,
  ) async {
    final failed = <String>{};
    final sourceKeys = <String>{};
    final destinationKeys = <String>{};
    var processed = 0;
    var total = 0;
    var counting = true;

    void publish() {
      moveStateListenable.value = MoveProgress(
        processed: processed,
        total: total,
        isCounting: counting,
      );
    }

    publish();

    // 把一批（≤并发数）对象 copy → deleteMany；单对象 copy 先于其源
    // delete 的不变式在批粒度成立，中断重跑幂等收敛。
    Future<void> moveChunk(List<({String key, String dst})> chunk) async {
      await Future.wait(chunk.map((item) async {
        try {
          await _ossClient.copy(item.key, item.dst, session);
        } catch (_) {
          // 复制失败可能源于上一轮已完成搬运（源已消失）：目标侧存在且源
          // 已不存在即视为完成；目录标记缺失时改用建目录方式补齐。
          final sourceExists = await _safeObjectExists(item.key, session);
          if (sourceExists) {
            failed.add(item.key);
          } else if (await _safeObjectExists(item.dst, session) ||
              (item.key.endsWith('/') &&
                  await _createDirectoryMarker(item.dst, session))) {
            // 已在上一轮完成 / 空目录标记补齐。
          } else {
            failed.add(item.key);
          }
        }
        processed++;
        publish();
      }));
      final pendingDeletes = chunk
          .map((item) => item.key)
          .where((key) => !failed.contains(key))
          .toSet();
      if (pendingDeletes.isEmpty) return;
      try {
        final result = await _ossClient.deleteMany(pendingDeletes, session);
        failed.addAll(result.failedPaths);
      } catch (_) {
        // 复制已成功但删除失败：目标侧已有副本，重跑可幂等收敛。
        failed.addAll(pendingDeletes);
      }
    }

    // 把一组 key 投入搬运（按批并发），并计入进度总数。
    Future<void> moveKeys(Iterable<String> keys, _MovePlanPair pair) async {
      final work = <({String key, String dst})>[
        for (final key in keys)
          (
            key: key,
            dst: key == pair.source
                ? pair.renameRoot
                : '${pair.renameRoot}${key.substring(pair.source.length)}',
          ),
      ];
      if (work.isEmpty) return;
      total += work.length;
      publish();
      sourceKeys.addAll(work.map((item) => item.key));
      destinationKeys.addAll(work.map((item) => item.dst));
      const concurrency = 6;
      for (var start = 0; start < work.length; start += concurrency) {
        final end = start + concurrency > work.length
            ? work.length
            : start + concurrency;
        await moveChunk(work.sublist(start, end));
      }
    }

    // 边列举边搬运：递归列举每返回一页即把该页投入搬运，列举下一页与
    // 搬运并发进行，总耗时 ≈ max(列举, 搬运) 而非两者相加。
    final pageJobs = <Future<void>>[];
    for (final pair in plan) {
      if (!pair.source.endsWith('/')) {
        pageJobs.add(moveKeys(<String>[pair.source], pair));
        continue;
      }
      // 目录标记单独投入：已完成的续迁中标记可能已随源消失，按幂等处理。
      pageJobs.add(moveKeys(<String>[pair.source], pair));
      await _ossClient.forEachObjectKeyPage(pair.source, session, (keys) async {
        final page = keys.where((key) => key != pair.source).toList();
        if (page.isEmpty) return;
        pageJobs.add(moveKeys(page, pair));
      });
    }
    counting = false;
    publish();
    await Future.wait(pageJobs);
    return MoveSummary(
      movedCount: sourceKeys.length - failed.length,
      failedKeys: failed.toList(growable: false),
      sourceKeys: sourceKeys,
      destinationKeys: destinationKeys,
    );
  }

  Future<bool> _safeObjectExists(String path, UserSession session) async {
    try {
      return await _ossClient.objectExists(path, session);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _createDirectoryMarker(String path, UserSession session) async {
    try {
      await _ossClient.createFolder(path, session);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 生成不冲突的目标路径：优先原名，其次「名称（n）」后缀，绝不覆盖。
  Future<String> _nonConflictingObjectPath(
      String desired, UserSession session) async {
    if (!await _ossClient.objectExists(desired, session)) return desired;
    final directory = parentPath(desired);
    final raw = desired.substring(directory.length);
    final isDirectory = raw.endsWith('/');
    final name = isDirectory ? raw.substring(0, raw.length - 1) : raw;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var number = 1;; number++) {
      final candidate =
          '$directory$stem（$number）$extension${isDirectory ? '/' : ''}';
      if (!await _ossClient.objectExists(candidate, session)) return candidate;
    }
  }

  Future<MoveConflictResolution?> _showMoveConflictDialog(
      List<String> conflictingNames) async {
    final context = _navigatorKey?.currentContext;
    if (context == null) {
      return null;
    }
    var selected = MoveConflictResolution.keepBoth;
    return showDialog<MoveConflictResolution>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: const Text('目标目录存在同名条目'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '「${conflictingNames.take(3).join('、')}'
                '${conflictingNames.length > 3 ? ' 等 ${conflictingNames.length} 项' : ''}」'
                '在目标目录已存在，请选择处理方式。',
              ),
              RadioGroup<MoveConflictResolution>(
                groupValue: selected,
                onChanged: (value) =>
                    setState(() => selected = value ?? selected),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    RadioListTile<MoveConflictResolution>(
                      title: const Text('保留两者'),
                      subtitle: const Text('同名条目自动追加序号后移动'),
                      value: MoveConflictResolution.keepBoth,
                    ),
                    RadioListTile<MoveConflictResolution>(
                      title: const Text('跳过'),
                      subtitle: const Text('跳过同名条目，移动其余内容'),
                      value: MoveConflictResolution.skip,
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消整个移动'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(selected),
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
  }

  /// 列出 OSS 上未完成的移动任务 manifest。
  Future<List<MoveTaskEntry>> listPendingMoves() async {
    await ensureSessionReady();
    final session = _requireSession();
    final prefixes = await _ossClient.listPrefixes(_movesRoot, session);
    final entries = <MoveTaskEntry>[];
    for (final prefix in prefixes) {
      try {
        entries.add(MoveTaskEntry.decode(
          utf8.decode(
              await _ossClient.download('$prefix' 'manifest.json', session)),
        ));
      } catch (_) {
        // manifest 未写完或已损坏，等待用户通过继续/撤销流程清理。
      }
    }
    entries.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return entries;
  }

  /// 继续未完成的移动：按 manifest 幂等重跑，已搬走的对象自然跳过。
  Future<MoveSummary> resumePendingMove(MoveTaskEntry entry) async {
    if (_isMoving) {
      throw StateError('已有移动任务进行中，请等待完成');
    }
    _ensureUploadCapability();
    _ensureDeleteCapability();
    await ensureSessionReady();
    final session = _requireSession();
    final plan = _planFromEntry(entry);
    final summary = await _executeMovePlan(
      plan: plan,
      targetPrefix: entry.targetPrefix,
      session: session,
      manifestId: entry.id,
    );
    _refreshAfterMove(
      entry.sourcePrefixes,
      plan.map((pair) => pair.renameRoot),
      summary,
    );
    unawaited(_galleryHooks?.onObjectsDeleted(summary.sourceKeys));
    unawaited(_galleryHooks?.onObjectsRestored(summary.destinationKeys));
    return summary;
  }

  /// 撤销未完成的移动：把目标侧已搬运对象反向搬回源位置，冲突时自动改名。
  Future<MoveSummary> undoPendingMove(MoveTaskEntry entry) async {
    if (_isMoving) {
      throw StateError('已有移动任务进行中，请等待完成');
    }
    _ensureUploadCapability();
    _ensureDeleteCapability();
    await ensureSessionReady();
    final session = _requireSession();
    final plan = _planFromEntry(entry);
    _isMoving = true;
    notifyListeners();
    final failed = <String>{};
    final deletedKeys = <String>{};
    final restoredKeys = <String>{};
    var processed = 0;
    var total = 0;
    var counting = true;

    void publish() {
      moveStateListenable.value = MoveProgress(
        processed: processed,
        total: total,
        isUndo: true,
        isCounting: counting,
      );
    }

    try {
      // 规划阶段要逐个探测源/目标对象（多次请求），先把“撤销中”状态
      // 公布出去，避免界面长时间无反馈。
      publish();
      Future<void> undoChunk(
          List<({String key, String dst, bool copyBack})> chunk) async {
        await Future.wait(chunk.map((item) async {
          if (item.copyBack) {
            try {
              await _ossClient.copy(item.key, item.dst, session);
            } catch (_) {
              failed.add(item.key);
            }
          }
          processed++;
          publish();
        }));
        final pendingDeletes = chunk
            .map((item) => item.key)
            .where((key) => !failed.contains(key))
            .toSet();
        if (pendingDeletes.isEmpty) return;
        try {
          final result = await _ossClient.deleteMany(pendingDeletes, session);
          failed.addAll(result.failedPaths);
        } catch (_) {
          failed.addAll(pendingDeletes);
        }
      }

      // 探测一组 key 的源位置占用并解析最终 dst，随后按批并发搬回。
      Future<void> undoKeys(List<String> keys, _MovePlanPair pair) async {
        const concurrency = 6;
        for (var start = 0; start < keys.length; start += concurrency) {
          final end =
              start + concurrency > keys.length ? keys.length : start + concurrency;
          final chunk = keys.sublist(start, end);
          final resolved = <({String key, String dst, bool copyBack})>[];
          await Future.wait(chunk.map((key) async {
            final relative = key.startsWith(pair.renameRoot) &&
                    pair.renameRoot.length > entry.targetPrefix.length
                ? key.substring(pair.renameRoot.length)
                : key.substring(entry.targetPrefix.length);
            var dst = '${pair.source}$relative';
            if (await _safeObjectExists(dst, session)) {
              // 源位置已有同名对象：中断批次常使源、目标两侧各存一份相同副本
              // （复制完成后尚未删源），此时直接丢弃目标侧副本即可恢复移动前
              // 状态；仅当两侧内容不同（源位置在移动期间被重新占用）时才改名
              // 保留目标侧副本。目录标记恒为 0 字节，直接判同。
              final duplicate = key.endsWith('/') ||
                  await _isSameObjectSize(key, dst, session);
              if (duplicate) {
                resolved.add((key: key, dst: key, copyBack: false));
                return;
              }
              dst = await _nonConflictingObjectPath(dst, session);
            }
            resolved.add((key: key, dst: dst, copyBack: true));
          }));
          total += resolved.length;
          publish();
          deletedKeys.addAll(resolved.map((item) => item.key));
          restoredKeys.addAll(
              resolved.where((item) => item.copyBack).map((item) => item.dst));
          await undoChunk(resolved);
        }
      }

      // 边列举边搬回：与正向移动一致，每页 key 到达即投入处理。
      final pageJobs = <Future<void>>[];
      for (final pair in plan) {
        if (!await _safeObjectExists(pair.renameRoot, session)) {
          // 目标侧不存在：未开始搬运或已被撤销，无需处理。
          debugPrint('[move] 撤销跳过：目标侧不存在 ${pair.renameRoot}');
          continue;
        }
        if (!pair.source.endsWith('/')) {
          pageJobs.add(undoKeys(<String>[pair.renameRoot], pair));
          continue;
        }
        // 目录标记单独投入：已撤销过的续跑中标记可能已随目标侧消失，幂等处理。
        pageJobs.add(undoKeys(<String>[pair.renameRoot], pair));
        await _ossClient.forEachObjectKeyPage(
            pair.renameRoot, session, (keys) async {
          final page = keys.where((key) => key != pair.renameRoot).toList();
          if (page.isEmpty) return;
          pageJobs.add(undoKeys(page, pair));
        });
      }
      counting = false;
      publish();
      await Future.wait(pageJobs);
      if (kDebugMode) {
        debugPrint(
          '[move] 撤销计划：${plan.map((p) => '${p.source} <= ${p.renameRoot}').join('；')}，待搬回 $total 项',
        );
      }
      if (failed.isEmpty) {
        try {
          await _ossClient.delete(
              '$_movesRoot${entry.id}/manifest.json', session);
        } catch (_) {
          // manifest 删除失败仅残留任务，不影响撤销结果。
        }
      }
    } finally {
      _isMoving = false;
      moveStateListenable.value = null;
      notifyListeners();
    }
    if (kDebugMode && failed.isNotEmpty) {
      debugPrint('[move] 撤销失败对象（前 5 个）: ${failed.take(5).join(', ')}');
    }
    // 撤销后失效目标侧缓存（目录从目标位置消失），源侧目录标记为存在。
    _refreshAfterMove(
      plan.map((pair) => pair.renameRoot).toSet(),
      entry.sourcePrefixes.toSet(),
      MoveSummary(
        movedCount: total - failed.length,
        failedKeys: failed.toList(growable: false),
      ),
    );
    unawaited(_galleryHooks?.onObjectsDeleted(deletedKeys));
    unawaited(_galleryHooks?.onObjectsRestored(restoredKeys));
    return MoveSummary(
        movedCount: total - failed.length,
        failedKeys: failed.toList(growable: false));
  }

  /// 以对象大小近似判断两个对象是否为同一副本（撤销场景的副本由复制产生）。
  Future<bool> _isSameObjectSize(
      String a, String b, UserSession session) async {
    final sizeA = await _objectSize(a, session);
    return sizeA != null && sizeA == await _objectSize(b, session);
  }

  Future<int?> _objectSize(String key, UserSession session) async {
    try {
      for (final object in await _ossClient.listAllObjects(key, session)) {
        if (object.key == key) {
          return object.size;
        }
      }
    } catch (_) {
      // 探测失败按“内容不同”处理，走改名保留路径。
    }
    return null;
  }

  List<_MovePlanPair> _planFromEntry(MoveTaskEntry entry) {
    return <_MovePlanPair>[
      for (var index = 0; index < entry.sourcePrefixes.length; index++)
        _MovePlanPair(
          source: entry.sourcePrefixes[index],
          renameRoot: entry.destinations.isNotEmpty &&
                  index < entry.destinations.length
              ? entry.destinations[index]
              : entry.targetPrefix +
                  entry.sourcePrefixes[index]
                      .substring(parentPath(entry.sourcePrefixes[index]).length),
        ),
    ];
  }

  /// 移动结束后统一刷新：目录缓存、侧边栏目录、当前路径与选择状态。
  void _refreshAfterMove(
    Iterable<String> removedPrefixes,
    Iterable<String> addedPrefixes,
    MoveSummary summary,
  ) {
    if (summary.movedCount == 0 && !summary.hasFailures) {
      return;
    }
    for (final prefix in removedPrefixes) {
      final dir = _normalizeDir(prefix);
      _workspaceController.removeBrowsedDirectoriesWhere(
          (path) => path == dir || path.startsWith(dir));
      if (currentPath.startsWith(dir)) {
        _workspaceController.replaceCurrentPath(parentPath(dir));
      }
    }
    _workspaceController.addBrowsedDirectories(addedPrefixes);
    _workspaceController.bumpTreeRevision();
    _workspaceController.clearDirectorySizeCache();
    // 移动同时修正源目录与目标目录：正向移动 removedPrefixes 为源条目、
    // addedPrefixes 为目标落点；撤销移动时两者互换，同一套修正逻辑成立。
    _workspaceController.noteTopLevelChanges(
      removedPrefixes,
      summary.hasFailures ? removedPrefixes.toSet() : const <String>{},
      delta: -1,
    );
    _workspaceController.noteTopLevelChanges(
      addedPrefixes,
      summary.hasFailures ? addedPrefixes.toSet() : const <String>{},
      delta: 1,
    );
    final selected = selectedItem;
    if (selected != null &&
        removedPrefixes.any(
            (prefix) => selected.path.startsWith(_normalizeDir(prefix)))) {
      _workspaceController.clearSelectedItem();
    }
    _workspaceController.clearMultiSelection();
    notifyListeners();
  }

  Future<void> uploadFile(
      {required String fileName,
      required String localPath,
      required int fileSize,
      String? targetPath,
      String? batchId}) =>
      _transferController.uploadFile(
        fileName: fileName,
        localPath: localPath,
        fileSize: fileSize,
        targetPath: targetPath,
        batchId: batchId,
      );

  Future<List<int>> downloadBytes(FileItem item) =>
      _transferController.downloadBytes(item);

  String enqueueDownload(
    FileItem item, {
    required String targetDirectory,
    String? batchId,
  }) =>
      _transferController.enqueueDownload(
        item,
        targetDirectory: targetDirectory,
        batchId: batchId,
      );

  /// 相册原图按需下载：写入相册专用缓存目录，完成后由回调写入缓存记录。
  /// 走现有传输队列，进度、取消与重试与普通下载一致。
  String enqueueOriginalDownload({
    required String path,
    required String name,
    required int? totalBytes,
    required File target,
    required Future<void> Function(File target) onCompleted,
  }) =>
      _transferController.enqueueOriginalDownload(
        path: path,
        name: name,
        totalBytes: totalBytes,
        target: target,
        onCompleted: onCompleted,
      );

  String enqueueDownloads(Iterable<FileItem> items,
          {required String targetDirectory}) =>
      _transferController.enqueueDownloads(items,
          targetDirectory: targetDirectory);

  /// 递归展开选中的文件夹，并将每个文件作为独立下载任务入队。
  ///
  /// 目录中的文件按其相对于当前文件视图的路径保存，避免拍平目录结构。
  Future<BatchDownloadEnqueueResult> enqueueDownloadsRecursively(
          Iterable<FileItem> items, {required String targetDirectory}) =>
      _transferController.enqueueDownloadsRecursively(items,
          targetDirectory: targetDirectory);

  Future<void> setTransferConcurrency(int value) =>
      _transferQueue.setTransferConcurrency(value);

  void retryTask(String taskId) => _transferController.retryTask(taskId);

  /// 对已失败或已取消的任务重新排队。
  void retryTasks(Iterable<String> taskIds) =>
      _transferController.retryTasks(taskIds);

  /// 继续「已中断」的上传任务：复用既有上传闭包重新入队。Android 与
  /// macOS 的大文件均为分片上传并保留 checkpoint，可从已传分片续传。
  /// 源文件缺失时直接标记失败。
  void resumeInterruptedUpload(String taskId) =>
      _transferController.resumeInterruptedUpload(taskId);

  /// 批量继续全部已中断上传任务（纯便利入口，逐个调用单任务操作）。
  void resumeAllInterruptedUploads() =>
      _transferController.resumeAllInterruptedUploads();

  /// 放弃「已中断」的上传任务：转已取消并清理对应 staging 文件。
  void abandonInterruptedUpload(String taskId) =>
      _transferController.abandonInterruptedUpload(taskId);

  /// 批量放弃全部已中断上传任务（纯便利入口，逐个调用单任务操作）。
  void abandonAllInterruptedUploads() =>
      _transferController.abandonAllInterruptedUploads();

  Set<String> get interruptedUploadTaskIds =>
      _transferController.interruptedUploadTaskIds;

  void cancelTask(String taskId) => _transferController.cancelTask(taskId);

  /// 取消正在等待或执行中的任务。
  void cancelTasks(Iterable<String> taskIds) =>
      _transferController.cancelTasks(taskIds);

  /// 一键暂停：停止调度等待中的任务；运行中的任务收到停止信号后回到
  /// 等待队列。上传任务（Android 与 macOS 均为分片 checkpoint）可从
  /// 已传分片续传；下载不支持断点，继续时从头下载。
  void pauseAllTransfers() => _transferController.pauseAllTransfers();

  /// 一键继续：解除队列暂停并立即调度等待中的任务。
  void resumeAllTransfers() => _transferController.resumeAllTransfers();

  /// 一键停止全部未完成任务（运行中与等待中），并解除队列暂停。
  void cancelAllTransfers() => _transferController.cancelAllTransfers();

  void clearCompletedTasks() => _transferController.clearCompletedTasks();

  /// 重置分享导入状态：清空待上传项与批次进度。取消弹窗时调用，
  /// 进行中批次的后续事件将被忽略（用户已放弃该批内容）。
  void prepareShareImport({List<ShareImportItem>? items, String? targetPath}) =>
      _shareImportController.prepareShareImport(
        items: items,
        targetPath: targetPath,
      );

  /// 批次开始：记录批次进度，弹窗可先于复制完成弹出。
  void beginShareImportBatch(String batchId, int total) =>
      _shareImportController.beginShareImportBatch(batchId, total);

  /// 批次内单个文件复制成功到达；不属于当前批次的到达项忽略。
  void addShareImportItem(String batchId, ShareImportItem item) =>
      _shareImportController.addShareImportItem(batchId, item);

  /// 批次完成：暂存项并入待上传清单；批次内全部失败时暂存项为空，
  /// 不进入待上传清单，仅保留失败计数供弹窗提示。
  void finishShareImportBatch(
    String batchId, {
    required int succeeded,
    required int failed,
  }) =>
      _shareImportController.finishShareImportBatch(
        batchId,
        succeeded: succeeded,
        failed: failed,
      );

  /// 冷启动兜底：原生缓冲中已完整的批次直接并入待上传清单，
  /// 视为「立即完成」的批次；全失败批次（无任何成功项）不弹窗。
  void addCompletedShareBatch(ShareImportCompleteBatch batch) =>
      _shareImportController.addCompletedShareBatch(batch);

  void setShareTargetPath(String path) =>
      _shareImportController.setShareTargetPath(path);

  Future<void> confirmShareUpload() =>
      _shareImportController.confirmShareUpload();

  List<String> get sidebarDirectories => _workspaceController.sidebarDirectories;

  void _ensureUploadCapability() {
    if (!capabilities.upload) {
      throw StateError('当前身份没有上传权限');
    }
  }

  void _ensureDeleteCapability() {
    if (!capabilities.delete) {
      throw StateError('当前身份没有删除权限');
    }
  }

  String _normalizeDir(String path) => path_utils.normalizeDirPath(path);

  @override
  void dispose() {
    _transferQueue.markRunningCanceled();
    for (final taskId in _transferQueue.runningTaskIds) {
      unawaited(_ossClient.cancelTransfer(taskId));
    }
    _workspaceController.dispose();
    moveStateListenable.dispose();
    deleteStateListenable.dispose();
    _shareImportController.dispose();
    _transferController.dispose();
    _transferQueue.dispose();
    _sessionController.dispose();
    super.dispose();
  }
}
