import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/errors/app_error.dart';
import '../../features/auth/domain/user_session.dart';
import '../../features/auth/infrastructure/saved_credentials_store.dart';
import '../../features/auth/infrastructure/session_repository.dart';
import '../../features/transfer/domain/transfer_task.dart';
import '../../features/preview/infrastructure/text_preview_loader.dart';
import '../../features/workspace/domain/file_item.dart';
import '../../features/workspace/domain/move_task_entry.dart';
import '../../features/workspace/domain/recycle_bin_entry.dart';
import '../../features/workspace/infrastructure/oss_client.dart';
import '../cache/disk_document_cache.dart';
import '../cache/disk_image_cache.dart';

class ShareImportItem {
  const ShareImportItem({
    required this.id,
    required this.name,
    required this.size,
    required this.localPath,
  });

  final String id;
  final String name;
  final int size;

  /// Android 系统分享时复制到应用缓存目录的本地文件路径。
  final String localPath;
}

class LoginResult {
  const LoginResult.success(this.session)
      : ok = true,
        message = null;

  const LoginResult.failure(this.message)
      : ok = false,
        session = null;

  final bool ok;
  final String? message;
  final UserSession? session;
}

class BatchDeletePreview {
  const BatchDeletePreview({
    required this.selectedCount,
    required this.directoryCount,
    required this.objectPaths,
  });

  final int selectedCount;
  final int directoryCount;
  final Set<String> objectPaths;
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

class BatchDownloadEnqueueResult {
  const BatchDownloadEnqueueResult({
    required this.batchId,
    required this.fileCount,
    required this.directoryCount,
  });

  final String batchId;
  final int fileCount;
  final int directoryCount;
}

/// 目标路径已存在时的移动处置决策；不提供覆盖选项，避免破坏幂等重跑安全性。
enum MoveConflictResolution { skip, keepBoth }

class MoveProgress {
  const MoveProgress({required this.processed, required this.total});

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

class DirectorySizeState {
  const DirectorySizeState._({this.size, required this.isLoading});

  const DirectorySizeState.loading() : this._(isLoading: true);

  const DirectorySizeState.ready(int size)
      : this._(size: size, isLoading: false);

  const DirectorySizeState.failed() : this._(isLoading: false);

  final int? size;
  final bool isLoading;
}

/// 上传目标已存在时的用户处置决策。
enum UploadConflictResolution { skip, overwrite, keepBoth }

typedef _UploadConflictDecision
    = ({UploadConflictResolution resolution, bool applyToBatch});

/// 任务因「已存在，跳过」而未发起上传时抛出，由传输执行器标记为完成。
class _UploadSkippedException implements Exception {
  const _UploadSkippedException();
}

/// 相册功能在传输与删除生命周期中的挂钩点。
/// 由 gallery 模块实现并在启动时注入；未注入时全部为空操作。
abstract interface class GalleryIndexHooks {
  /// 视频上传前启动本地截帧（与上传并行）；返回截帧 JPEG 的本地路径，
  /// 截帧失败返回 null，不阻塞上传。
  Future<String?> prepareVideoThumbnail(String objectPath, String localPath);

  /// 超大图片上传前本地生成缩略图（与上传并行）；非超大图或生成失败
  /// 返回 null，不阻塞上传。
  Future<String?> prepareImageThumbnail(String objectPath, String localPath);

  /// 媒体上传成功后触发索引增量更新（非媒体文件由实现方过滤）。
  Future<void> onMediaUploaded({
    required String objectPath,
    required String localPath,
    String? thumbLocalPath,
  });

  /// 对象删除成功后触发索引增量清理（对象 key，含目录展开结果）。
  Future<void> onObjectsDeleted(Set<String> objectKeys);

  /// 对象从回收站还原后重新纳入索引。
  Future<void> onObjectsRestored(Set<String> objectKeys);
}

/// 应用状态控制器。会话与权限来自已部署的 FC，不在生产路径伪造身份。
class AppController extends ChangeNotifier {
  AppController(
      {required SessionRepository sessionRepository,
      OssClient? ossClient,
      SavedCredentialsStore? savedCredentialsStore})
      : _sessionRepository = sessionRepository,
        _ossClient = ossClient ?? OssClient(),
        _savedCredentialsStore =
            savedCredentialsStore ?? SavedCredentialsStore() {
    _ossClient.onCredentialExpired = handleCredentialExpired;
  }

  final SessionRepository _sessionRepository;
  final OssClient _ossClient;

  /// 相册等模块与主控制器共用同一个 OSS 客户端（凭证配置状态共享）。
  OssClient get ossClient => _ossClient;
  final SavedCredentialsStore _savedCredentialsStore;
  GalleryIndexHooks? _galleryHooks;

  /// 注入相册索引挂钩（上传增量更新、删除清理、还原恢复）。
  void setGalleryHooks(GalleryIndexHooks? hooks) {
    _galleryHooks = hooks;
  }

  /// 全局 Navigator Key，供传输队列内弹出上传冲突处置对话框。
  GlobalKey<NavigatorState>? _navigatorKey;

  void setNavigatorKey(GlobalKey<NavigatorState>? key) {
    _navigatorKey = key;
  }

  /// 批次级「整批应用」决策；同批其余已存在任务直接复用。
  final Map<String, UploadConflictResolution> _batchConflictResolutions =
      <String, UploadConflictResolution>{};

  /// 正在等待批次决策的任务共享同一个 Completer，保证一批只弹一次对话框。
  final Map<String, Completer<_UploadConflictDecision?>>
      _batchConflictWaiters = <String, Completer<_UploadConflictDecision?>>{};

  static const rootPrefix = 'shared/';
  static const _movesRoot = '$rootPrefix.moves/';
  static const _transferConcurrencyKey = 'transfer_concurrency';
  static const _transferHistoryKey = 'transfer_history:v1';
  static const _fileSortOptionKey = 'file_sort_option';
  static const _fileSortOptionsByDirectoryKey =
      'file_sort_options_by_directory';
  static const _themeModeKey = 'theme_mode';
  static const _autoCheckUpdatesKey = 'auto_check_updates';
  static const _thumbnailSizeKey = 'thumbnail_size';
  static const _takenAtCachePrefix = 'image_taken_at:v5:';
  static const _videoFileExtensions = <String>{
    'mp4', 'mov', 'm4v', 'mkv', 'avi', 'webm', '3gp',
  };
  static const _imageFileExtensions = <String>{
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp',
  };
  static const _minTransferConcurrency = 1;
  static const _maxTransferConcurrency = 5;

  /// Selection updates only; does not rebuild the whole app shell.
  final ValueNotifier<FileItem?> selectedItemListenable =
      ValueNotifier<FileItem?>(null);

  final ValueNotifier<Set<String>> multiSelectedPathsListenable =
      ValueNotifier<Set<String>>(<String>{});

  /// 仅用于详情页的目录大小异步计算状态，避免重建整个工作区。
  final ValueNotifier<Map<String, DirectorySizeState>>
      directorySizeStatesListenable =
      ValueNotifier<Map<String, DirectorySizeState>>(
          const <String, DirectorySizeState>{});
  final Map<String, int> _directorySizeCache = <String, int>{};
  final Map<String, Object> _directorySizeRequests = <String, Object>{};

  /// Transfer task list/progress updates only; does not rebuild workspace.
  final ValueNotifier<List<TransferTask>> tasksListenable =
      ValueNotifier<List<TransferTask>>(<TransferTask>[]);

  /// 总并发数单独通知，避免传输进度刷新整个设置区域。
  final ValueNotifier<int> transferConcurrencyListenable =
      ValueNotifier<int>(3);

  /// 移动进行中状态（已处理/总对象数）；仅工作区条目区消费，避免整页重建。
  final ValueNotifier<MoveProgress?> moveStateListenable =
      ValueNotifier<MoveProgress?>(null);
  bool _isMoving = false;

  UserSession? _session;
  String _currentPath = rootPrefix;
  BrowseMode _browseMode = BrowseMode.list;
  ThumbnailSize _thumbnailSize = ThumbnailSize.medium;
  FileSortOption _defaultFileSortOption = FileSortOption.updatedNewest;
  final Map<String, FileSortOption> _fileSortOptionsByDirectory =
      <String, FileSortOption>{};
  final Set<String> _remoteDirectories = <String>{};
  List<ShareImportItem> _pendingShareItems = const <ShareImportItem>[];
  String _shareTargetPath = rootPrefix;
  bool _bootstrapped = false;
  ThemeMode _themeMode = ThemeMode.light;
  bool _autoCheckUpdates = true;
  int _treeRevision = 0;
  bool _isMultiSelectionMode = false;
  String? _selectionAnchorPath;

  final List<String> _pendingTransferIds = <String>[];
  final Set<String> _runningTransferIds = <String>{};
  final Map<String, _QueuedTransfer> _queuedTransfers =
      <String, _QueuedTransfer>{};
  final Set<String> _canceledTransferIds = <String>{};
  int _nextTransferId = 0;
  SharedPreferences? _preferences;
  bool _transferHistoryReady = false;
  bool _isSavingTransferHistory = false;
  bool _transferHistoryDirty = false;

  UserSession? get session => _session;
  bool get isLoggedIn => _session != null;
  String get currentPath => _currentPath;

  String _recycleBinPath = rootPrefix;

  String get recycleBinPath => _recycleBinPath;

  void setRecycleBinPath(String path) {
    _recycleBinPath = _normalizeDir(path);
    notifyListeners();
  }

  /// 将 OSS 内部对象键转换为用户可见的相对路径。
  String displayPath(String path) {
    final normalized = path.trim();
    final root = _session?.rootPrefix.isNotEmpty == true
        ? _normalizeDir(_session!.rootPrefix)
        : rootPrefix;
    if (normalized.isEmpty || normalized == root) {
      return '全部文件';
    }
    final relative = normalized.startsWith(root)
        ? normalized.substring(root.length)
        : normalized;
    return relative.replaceFirst(RegExp(r'/$'), '').isEmpty
        ? '全部文件'
        : relative.replaceFirst(RegExp(r'/$'), '');
  }

  BrowseMode get browseMode => _browseMode;
  ThumbnailSize get thumbnailSize => _thumbnailSize;
  FileSortOption get fileSortOption => _fileSortOptionForPath(_currentPath);
  List<TransferTask> get tasks => tasksListenable.value;
  int get transferConcurrency => transferConcurrencyListenable.value;
  int get runningTransferCount => _runningTransferIds.length;
  int get pendingTransferCount => _pendingTransferIds.length;
  bool get isMoving => _isMoving;

  List<ShareImportItem> get pendingShareItems =>
      List<ShareImportItem>.unmodifiable(_pendingShareItems);
  String get shareTargetPath => _shareTargetPath;
  FileItem? get selectedItem => selectedItemListenable.value;
  bool get isMultiSelectionMode => _isMultiSelectionMode;
  int get multiSelectedCount => multiSelectedPathsListenable.value.length;
  Set<String> get multiSelectedPaths => multiSelectedPathsListenable.value;
  bool get bootstrapped => _bootstrapped;
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
  int get treeRevision => _treeRevision;
  Capabilities get capabilities =>
      _session?.capabilities ?? const Capabilities.member();

  Future<void> bootstrap() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _preferences = preferences;
      final savedConcurrency = preferences.getInt(_transferConcurrencyKey);
      if (savedConcurrency != null &&
          savedConcurrency >= _minTransferConcurrency &&
          savedConcurrency <= _maxTransferConcurrency) {
        transferConcurrencyListenable.value = savedConcurrency;
      }
      _restoreSortPreferences(preferences);
      _restoreTransferHistory(preferences);
      _restoreThemeMode(preferences);
      _restoreThumbnailSize(preferences);
      _restoreAutoCheckUpdates(preferences);
      _transferHistoryReady = true;
    } catch (_) {
      // 偏好读取失败不应阻断会话恢复。
    }
    try {
      final restored = await _sessionRepository.restore();
      if (restored != null && restored.isRemote) {
        _session = restored;
        _currentPath =
            restored.rootPrefix.isEmpty ? rootPrefix : restored.rootPrefix;
        await _ossClient.configureSession(restored);
      }
    } catch (_) {
      // Keep app usable even if secure storage restore fails.
    }
    _bootstrapped = true;
    notifyListeners();
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
  }) async {
    try {
      final session = await _sessionRepository.login(
        account: account,
        password: password,
      );
      _session = session;
      _currentPath =
          session.rootPrefix.isEmpty ? rootPrefix : session.rootPrefix;
      if (session.isRemote) {
        await _ossClient.configureSession(session);
      }
      selectedItemListenable.value = null;
      _clearDirectorySizeCache();
      await _rememberCredentials(account: account.trim(), password: password);
      notifyListeners();
      return LoginResult.success(session);
    } on AppError catch (error) {
      return LoginResult.failure(error.message);
    } catch (error) {
      debugPrint('[login] unexpected error: $error');
      return const LoginResult.failure('登录失败，请稍后重试');
    }
  }

  /// 供登录页预填最近一次成功登录的用户名与密码。
  Future<SavedCredentials?> readSavedCredentials() {
    return _savedCredentialsStore.read();
  }

  Future<void> _rememberCredentials({
    required String account,
    required String password,
  }) async {
    try {
      await _savedCredentialsStore.write(
        SavedCredentials(account: account, password: password),
      );
    } catch (_) {
      // 凭据记忆失败不应影响登录流程。
    }
  }

  Future<void> logout() async {
    for (final taskId in _runningTransferIds) {
      _canceledTransferIds.add(taskId);
      unawaited(_ossClient.cancelTransfer(taskId));
    }
    await _ossClient.clearConfiguration();
    await _sessionRepository.logout();
    _session = null;
    _remoteDirectories.clear();
    selectedItemListenable.value = null;
    _clearDirectorySizeCache();
    clearMultiSelection();
    _pendingShareItems = const <ShareImportItem>[];
    _pendingTransferIds.clear();
    _batchConflictResolutions.clear();
    notifyListeners();
  }

  Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final session = _session;
    if (session == null) {
      return '请先登录';
    }
    if (newPassword.length < 8) {
      return '新密码至少需要 8 个字符';
    }
    try {
      _session = await _sessionRepository.changePassword(
        session: session,
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      await _rememberCredentials(
        account: session.account,
        password: newPassword,
      );
      notifyListeners();
      return null;
    } on AppError catch (error) {
      return error.message;
    } catch (error) {
      debugPrint('[changePassword] unexpected error: $error');
      return '修改失败，请稍后重试';
    }
  }

  /// 校验当前会话可用。访问密钥为登录下发的长期密钥，
  /// 无需刷新；失效时由 [handleCredentialExpired] 引导重新登录。
  Future<void> ensureSessionReady() async {
    final session = _session;
    if (session == null || !session.isRemote) {
      return;
    }
    if (session.credentials?.isValid != true) {
      throw AppError('会话缺少 OSS 凭证，请重新登录', code: 'REMOTE_SESSION_REQUIRED');
    }
    await _ossClient.configureSession(session);
  }

  /// OSS 鉴权失败（密钥被撤销等）时清除会话，由外层引导用户重新登录。
  void handleCredentialExpired() {
    if (_session == null) {
      return;
    }
    unawaited(logout());
  }

  UserSession _requireSession() {
    final session = _session;
    if (session == null || !session.isRemote || session.credentials == null) {
      throw AppError('请先登录', code: 'REMOTE_SESSION_REQUIRED');
    }
    return session;
  }

  Future<List<FileItem>> listDirectory([String? path]) async {
    final session = _session;
    if (session == null || !session.isRemote || session.credentials == null) {
      throw AppError('请先登录', code: 'REMOTE_SESSION_REQUIRED');
    }
    await ensureSessionReady();
    final items = await _ossClient.list(path ?? _currentPath, _session!);
    if ((path ?? _currentPath) == _currentPath) {
      final beforeCount = _remoteDirectories.length;
      _remoteDirectories
        ..add(_currentPath)
        ..addAll(
            items.where((item) => item.isDirectory).map((item) => item.path));
      if (_remoteDirectories.length != beforeCount) {
        notifyListeners();
      }
    }
    return _sortDirectoryItems(
      items,
      _session!,
      _fileSortOptionForPath(path ?? _currentPath),
    );
  }

  Future<List<int>> loadThumbnail(FileItem item) async {
    if (item.isDirectory || item.kind != FileKind.image) {
      throw StateError('只有图片文件支持缩略图');
    }
    final session = _requireSession();
    await ensureSessionReady();
    final cacheKey = DiskImageCache.cacheKey(
      namespace: thumbnailCacheNamespace,
      path: item.path,
      versionToken: item.objectVersionToken,
      process: ImageThumbnailSpec.process(),
    );
    final cached = await DiskImageCache.instance.read(
      DiskImageCacheKind.thumbnails,
      cacheKey,
    );
    if (cached != null) {
      return cached;
    }
    final bytes =
        await _ossClient.downloadThumbnail(item.path, _session ?? session);
    unawaited(DiskImageCache.instance.write(
      DiskImageCacheKind.thumbnails,
      cacheKey,
      bytes,
    ));
    return bytes;
  }

  Future<List<int>> loadImagePreview(FileItem item) async {
    if (item.isDirectory || item.kind != FileKind.image) {
      throw StateError('只有图片文件支持在线预览');
    }
    final session = _requireSession();
    await ensureSessionReady();
    final cacheKey = DiskImageCache.cacheKey(
      namespace: thumbnailCacheNamespace,
      path: item.path,
      versionToken: item.objectVersionToken,
      process: ImageThumbnailSpec.process(
        width: ImageThumbnailSpec.previewSize,
        height: ImageThumbnailSpec.previewSize,
      ),
    );
    final cached = await DiskImageCache.instance.read(
      DiskImageCacheKind.previews,
      cacheKey,
    );
    if (cached != null) return cached;
    final bytes =
        await _ossClient.downloadImagePreview(item.path, _session ?? session);
    unawaited(DiskImageCache.instance.write(
      DiskImageCacheKind.previews,
      cacheKey,
      bytes,
    ));
    return bytes;
  }

  String get thumbnailCacheNamespace {
    final session = _session;
    final bucket = session?.ossConfig?.bucket ?? '';
    return '$bucket|${session?.userId ?? ''}';
  }

  /// 加载 PDF 文档本地文件：缓存命中直接返回；未命中走预签名 URL
  /// 流式下载落盘后写入文档缓存。失败时抛出异常由界面展示重试。
  Future<File> loadPdfDocument(FileItem item) async {
    if (item.isDirectory || item.kind != FileKind.pdf) {
      throw StateError('只有 PDF 文件支持文档预览');
    }
    final session = _requireSession();
    await ensureSessionReady();
    final cacheKey = DiskDocumentCache.cacheKey(
      namespace: thumbnailCacheNamespace,
      path: item.path,
      versionToken: item.objectVersionToken,
    );
    final cached = await DiskDocumentCache.instance.get(cacheKey);
    if (cached != null) return cached;
    final temporary = await DiskDocumentCache.instance.createTemporaryFile();
    if (temporary == null) {
      throw AppError('本地缓存不可用，无法预览 PDF', code: 'DOC_CACHE_UNAVAILABLE');
    }
    try {
      await _ossClient.streamDownloadToFile(
        item.path,
        session,
        temporary,
      );
    } catch (_) {
      await DiskDocumentCache.instance.discard(temporary);
      rethrow;
    }
    final committed =
        await DiskDocumentCache.instance.commit(cacheKey, temporary);
    if (committed == null) {
      throw AppError('PDF 缓存写入失败', code: 'DOC_CACHE_WRITE_FAILED');
    }
    return committed;
  }

  /// 创建文本预览分段加载器（编码与 20MB 上限策略内聚在加载器中）。
  TextPreviewLoader createTextPreviewLoader(FileItem item) {
    final session = _requireSession();
    return TextPreviewLoader(
      ossClient: _ossClient,
      session: session,
      path: item.path,
      fileSize: item.size,
    );
  }

  /// 生成音频等对象的预签名 URL，用于 media_kit 流式播放。
  Future<String> presignMediaUrl(FileItem item) async {
    final session = _requireSession();
    await ensureSessionReady();
    return _ossClient.presignObjectUrl(item.path, _session ?? session);
  }

  void setCurrentPath(String path) {
    _currentPath = _normalizeDir(path);
    selectedItemListenable.value = null;
    clearMultiSelection();
    notifyListeners();
  }

  void setBrowseMode(BrowseMode mode) {
    if (_browseMode == mode) {
      return;
    }
    _browseMode = mode;
    notifyListeners();
  }

  Future<void> setThumbnailSize(ThumbnailSize size) async {
    if (_thumbnailSize == size) {
      return;
    }
    _thumbnailSize = size;
    notifyListeners();
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setString(_thumbnailSizeKey, size.name);
    } catch (_) {
      // 偏好写入失败时仍保留本次会话的选择。
    }
  }

  Future<void> setFileSortOption(FileSortOption option) async {
    final key = _directorySortKey(_currentPath);
    if (_fileSortOptionsByDirectory[key] == option) return;
    _fileSortOptionsByDirectory[key] = option;
    notifyListeners();
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _fileSortOptionsByDirectoryKey,
        jsonEncode(
          _fileSortOptionsByDirectory.map(
            (key, value) => MapEntry<String, int>(key, value.index),
          ),
        ),
      );
    } catch (_) {
      // 排序偏好写入失败不影响当前会话内的排序。
    }
  }

  Future<List<FileItem>> _sortDirectoryItems(
    List<FileItem> items,
    UserSession session,
    FileSortOption sortOption,
  ) async {
    if (!sortOption.needsTakenAt) {
      return sortFileItems(items, sortOption);
    }

    SharedPreferences? preferences;
    try {
      preferences = await SharedPreferences.getInstance();
    } catch (_) {
      // 读取 EXIF 仍可用，只是不跨重启缓存。
    }
    // 避免大目录首次按拍摄时间排序时同时发起过多 OSS 请求。
    const concurrency = 6;
    final resolved = <FileItem>[];
    for (var start = 0; start < items.length; start += concurrency) {
      final end = start + concurrency > items.length
          ? items.length
          : start + concurrency;
      resolved.addAll(await Future.wait(items.sublist(start, end).map(
            (item) => _loadItemTakenAt(item, session, preferences),
          )));
    }
    return sortFileItems(resolved, sortOption);
  }

  void _restoreSortPreferences(SharedPreferences preferences) {
    // 保留旧版本的全局排序作为未单独设置目录时的默认值。
    final savedSort = preferences.getInt(_fileSortOptionKey);
    if (savedSort != null &&
        savedSort >= 0 &&
        savedSort < FileSortOption.values.length) {
      _defaultFileSortOption = FileSortOption.values[savedSort];
    }
    final raw = preferences.getString(_fileSortOptionsByDirectoryKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final index = entry.value is num ? (entry.value as num).toInt() : null;
        if (entry.key is String &&
            index != null &&
            index >= 0 &&
            index < FileSortOption.values.length) {
          _fileSortOptionsByDirectory[entry.key as String] =
              FileSortOption.values[index];
        }
      }
    } catch (_) {
      // 本地偏好损坏时使用默认排序，不阻断会话恢复。
    }
  }

  void _restoreThemeMode(SharedPreferences preferences) {
    _themeMode = switch (preferences.getString(_themeModeKey)) {
      'dark' => ThemeMode.dark,
      _ => ThemeMode.light,
    };
  }

  void _restoreThumbnailSize(SharedPreferences preferences) {
    _thumbnailSize = switch (preferences.getString(_thumbnailSizeKey)) {
      'small' => ThumbnailSize.small,
      'large' => ThumbnailSize.large,
      _ => ThumbnailSize.medium,
    };
  }

  void _restoreAutoCheckUpdates(SharedPreferences preferences) {
    _autoCheckUpdates = preferences.getBool(_autoCheckUpdatesKey) ?? true;
  }

  FileSortOption _fileSortOptionForPath(String path) =>
      _fileSortOptionsByDirectory[_directorySortKey(path)] ??
      _defaultFileSortOption;

  String _directorySortKey(String path) {
    final session = _session;
    final bucket = session?.ossConfig?.bucket ?? '';
    final userId = session?.userId ?? '';
    return '$bucket:$userId:${_normalizeDir(path)}';
  }

  String _takenAtCacheKey(UserSession session, String path) {
    final bucket = session.ossConfig?.bucket ?? '';
    return '$_takenAtCachePrefix$bucket:${session.userId}:$path';
  }

  Future<FileItem> _loadItemTakenAt(
    FileItem item,
    UserSession session, [
    SharedPreferences? preferences,
  ]) async {
    if (item.isDirectory ||
        item.kind != FileKind.image ||
        item.takenAt != null) {
      return item;
    }
    SharedPreferences? cache = preferences;
    if (cache == null) {
      try {
        cache = await SharedPreferences.getInstance();
      } catch (_) {
        // 无本地缓存时仍尝试读取 EXIF。
      }
    }
    final version = item.objectVersionToken;
    final cacheKey = _takenAtCacheKey(session, item.path);
    final cached = cache?.getString(cacheKey);
    if (cached != null) {
      final parts = cached.split('\t');
      if (parts.length == 2 && parts.first == version) {
        final milliseconds = int.tryParse(parts.last);
        return milliseconds == null
            ? item
            : item.copyWith(
                takenAt: DateTime.fromMillisecondsSinceEpoch(milliseconds));
      }
    }

    DateTime? takenAt;
    try {
      takenAt = await _ossClient
          .readImageExif(item.path, session)
          .then((info) => info.takenAt);
    } catch (_) {
      // OSS 图片处理异常时不缓存，后续进入详情或排序时允许重新尝试。
      return item;
    }
    if (cache != null) {
      try {
        await cache.setString(
          cacheKey,
          '$version\t${takenAt?.millisecondsSinceEpoch ?? ''}',
        );
      } catch (_) {
        // 缓存写入失败不影响本次展示。
      }
    }
    return item.copyWith(takenAt: takenAt);
  }

  void selectItem(FileItem? item) {
    final current = selectedItemListenable.value;
    if (current?.path == item?.path &&
        current?.name == item?.name &&
        current?.isDirectory == item?.isDirectory) {
      // Keep object fresh for rename/metadata without extra noise when identical.
      if (!identical(current, item)) {
        selectedItemListenable.value = item;
      }
      if (item?.isDirectory ?? false) {
        unawaited(_loadDirectorySize(item!));
      }
      return;
    }
    selectedItemListenable.value = item;
    if (item != null && item.kind == FileKind.image && item.takenAt == null) {
      unawaited(_loadSelectedImageTakenAt(item));
    }
    if (item?.isDirectory ?? false) {
      unawaited(_loadDirectorySize(item!));
    }
  }

  Future<void> _loadDirectorySize(FileItem item) async {
    final path = _normalizeDir(item.path);
    final cached = _directorySizeCache[path];
    if (cached != null) {
      _setDirectorySizeState(path, DirectorySizeState.ready(cached));
      return;
    }
    if (_directorySizeRequests.containsKey(path)) return;

    final request = Object();
    _directorySizeRequests[path] = request;
    _setDirectorySizeState(path, const DirectorySizeState.loading());
    try {
      await ensureSessionReady();
      final size = await _ossClient.calculateDirectorySize(
        path,
        _requireSession(),
      );
      if (_directorySizeRequests[path] == request) {
        _directorySizeCache[path] = size;
        _setDirectorySizeState(path, DirectorySizeState.ready(size));
      }
    } catch (_) {
      if (_directorySizeRequests[path] == request) {
        _setDirectorySizeState(path, const DirectorySizeState.failed());
      }
    } finally {
      if (_directorySizeRequests[path] == request) {
        _directorySizeRequests.remove(path);
      }
    }
  }

  void _setDirectorySizeState(String path, DirectorySizeState state) {
    directorySizeStatesListenable.value = Map<String,
        DirectorySizeState>.unmodifiable(<String, DirectorySizeState>{
      ...directorySizeStatesListenable.value,
      path: state,
    });
  }

  void _clearDirectorySizeCache() {
    _directorySizeCache.clear();
    _directorySizeRequests.clear();
    directorySizeStatesListenable.value = const <String, DirectorySizeState>{};
  }

  Future<void> _loadSelectedImageTakenAt(FileItem item) async {
    final session = _session;
    if (session == null || !session.isRemote || session.credentials == null) {
      return;
    }
    final resolved = await _loadItemTakenAt(item, session);
    final selected = selectedItemListenable.value;
    if (selected?.path == item.path &&
        selected?.objectVersionToken == item.objectVersionToken) {
      selectedItemListenable.value = resolved;
    }
  }

  void enterMultiSelection([FileItem? initial]) {
    _isMultiSelectionMode = true;
    if (initial != null) {
      _selectionAnchorPath = initial.path;
      multiSelectedPathsListenable.value = <String>{initial.path};
    }
    notifyListeners();
  }

  void toggleMultiSelection(FileItem item,
      {List<FileItem>? visibleItems, bool range = false}) {
    if (!_isMultiSelectionMode) {
      enterMultiSelection(item);
      return;
    }
    final next = <String>{...multiSelectedPathsListenable.value};
    if (range && visibleItems != null && _selectionAnchorPath != null) {
      final anchor = visibleItems
          .indexWhere((value) => value.path == _selectionAnchorPath);
      final target =
          visibleItems.indexWhere((value) => value.path == item.path);
      if (anchor >= 0 && target >= 0) {
        final start = anchor < target ? anchor : target;
        final end = anchor > target ? anchor : target;
        next.addAll(
            visibleItems.sublist(start, end + 1).map((value) => value.path));
      }
    } else if (!next.add(item.path)) {
      next.remove(item.path);
    } else {
      _selectionAnchorPath = item.path;
    }
    if (next.isEmpty) {
      _isMultiSelectionMode = false;
      _selectionAnchorPath = null;
    }
    multiSelectedPathsListenable.value = Set<String>.unmodifiable(next);
    notifyListeners();
  }

  void selectAllItems(Iterable<FileItem> items) {
    _isMultiSelectionMode = true;
    multiSelectedPathsListenable.value =
        Set<String>.unmodifiable(items.map((item) => item.path).toSet());
    notifyListeners();
  }

  /// 用于桌面端拖拽框选，以一次状态更新替换当前可见项的选择结果。
  void replaceMultiSelection(Iterable<String> paths) {
    final next = Set<String>.unmodifiable(paths.toSet());
    _isMultiSelectionMode = next.isNotEmpty;
    _selectionAnchorPath = next.isEmpty ? null : next.last;
    multiSelectedPathsListenable.value = next;
    notifyListeners();
  }

  void clearMultiSelection() {
    _isMultiSelectionMode = false;
    _selectionAnchorPath = null;
    // 即使当前尚未选中条目，也必须发布一次空集合，令依赖该监听器的
    // 文件视图从选择模式重建回普通浏览模式。
    multiSelectedPathsListenable.value = Set<String>.unmodifiable(<String>{});
    notifyListeners();
  }

  /// 在当前目录的可见排序中移动当前项，不改变批量勾选状态。
  bool moveSelection(
    List<FileItem> visibleItems, {
    required int offset,
  }) {
    if (visibleItems.isEmpty || offset == 0) {
      return false;
    }

    final selectedPath = selectedItemListenable.value?.path;
    var currentIndex = visibleItems.indexWhere(
      (item) => item.path == selectedPath,
    );
    if (currentIndex < 0) {
      currentIndex = offset > 0 ? 0 : visibleItems.length - 1;
    }
    final targetIndex =
        (currentIndex + offset).clamp(0, visibleItems.length - 1);
    final target = visibleItems[targetIndex];

    clearMultiSelection();
    selectItem(target);
    return true;
  }

  String parentPath(String path) {
    final normalized = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final idx = normalized.lastIndexOf('/');
    if (idx <= 0) {
      return rootPrefix;
    }
    return normalized.substring(0, idx + 1);
  }

  Future<void> createFolder(String name, {String? targetPath}) async {
    _ensureUploadCapability();
    final folderName = name.trim();
    if (folderName.isEmpty) {
      throw StateError('文件夹名称不能为空');
    }
    final dir = _normalizeDir(targetPath ?? _currentPath);
    final path = '$dir$folderName/';
    await ensureSessionReady();
    await _ossClient.createFolder(path, _requireSession());
    _clearDirectorySizeCache();
    _treeRevision++;
    notifyListeners();
  }

  Future<void> renameItem(FileItem item, String newName) async {
    _ensureDeleteCapability(); // rename treated as write capability with delete/upload
    if (!capabilities.upload && !capabilities.delete) {
      throw StateError('当前身份没有重命名权限');
    }
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      throw StateError('名称不能为空');
    }

    final parent =
        item.isDirectory ? parentPath(item.path) : parentPath(item.path);
    final dir = _normalizeDir(parent == item.path ? rootPrefix : parent);
    final newPath = item.isDirectory ? '$dir$trimmed/' : '$dir$trimmed';
    await ensureSessionReady();
    final session = _requireSession();
    await _ossClient.copy(item.path, newPath, session);
    await _ossClient.delete(item.path, session);
    _treeRevision++;
    _clearDirectorySizeCache();
    notifyListeners();
  }

  Future<void> deleteItem(FileItem item) async {
    _ensureDeleteCapability();
    await ensureSessionReady();
    final session = _requireSession();
    final paths = <String>{item.path};
    if (item.isDirectory) {
      paths.addAll(await _ossClient.listAllObjectKeys(item.path, session));
    }
    final result = await _moveToRecycleBin(
      paths,
      name: item.name,
      originalPath: item.path,
      isDirectory: item.isDirectory,
      session: session,
    );
    if (result.failedPaths.isNotEmpty) {
      throw StateError('有 ${result.failedPaths.length} 个对象未能移入回收站');
    }
    if (item.isDirectory) {
      final deletedPath = _normalizeDir(item.path);
      _remoteDirectories.removeWhere(
        (path) => path == deletedPath || path.startsWith(deletedPath),
      );
      if (_currentPath.startsWith(deletedPath)) {
        _currentPath = parentPath(deletedPath);
      }
    }
    _treeRevision++;
    _clearDirectorySizeCache();

    if (selectedItemListenable.value?.path == item.path) {
      selectedItemListenable.value = null;
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
      _ensureWithinRoot(item.path);
      paths.add(item.path);
      if (item.isDirectory) {
        paths.addAll(await _ossClient.listAllObjectKeys(item.path, session));
      }
    }
    return BatchDeletePreview(
      selectedCount: selected.length,
      directoryCount: selected.where((item) => item.isDirectory).length,
      objectPaths: paths,
    );
  }

  Future<BatchDeleteSummary> deleteBatch(
    BatchDeletePreview preview,
  ) async {
    _ensureDeleteCapability();
    await ensureSessionReady();
    final result = await _moveToRecycleBin(
      preview.objectPaths,
      name: preview.selectedCount == 1
          ? '已删除项目'
          : '已删除 ${preview.selectedCount} 项',
      originalPath: _currentPath,
      isDirectory: preview.directoryCount > 0,
      session: _requireSession(),
    );
    final deleted = result.deletedPaths;
    final failed = result.failedPaths;
    if (deleted.isNotEmpty) {
      _clearDirectorySizeCache();
      _remoteDirectories.removeWhere((path) => deleted.contains(path));
      if (deleted.any((path) => _currentPath.startsWith(_normalizeDir(path)))) {
        _currentPath = parentPath(_currentPath);
      }
      _treeRevision++;
      selectedItemListenable.value = null;
      unawaited(_galleryHooks?.onObjectsDeleted(deleted.toSet()));
      notifyListeners();
    }
    return BatchDeleteSummary(deletedPaths: deleted, failedPaths: failed);
  }

  Future<BatchDeleteSummary> _moveToRecycleBin(
    Iterable<String> sourcePaths, {
    required String name,
    required String originalPath,
    required bool isDirectory,
    required UserSession session,
  }) async {
    final sources =
        sourcePaths.toSet().where((path) => path.startsWith(rootPrefix));
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final batchRoot = '$rootPrefix.trash/$id/';
    final copied = <String, String>{};
    final failed = <String>[];
    for (final source in sources) {
      final target =
          '$batchRoot' 'payload/${source.substring(rootPrefix.length)}';
      try {
        await _ossClient.copy(source, target, session);
        copied[source] = target;
      } catch (_) {
        failed.add(source);
      }
    }
    if (copied.isNotEmpty) {
      final entry = RecycleBinEntry(
        id: id,
        name: name,
        originalPath: originalPath,
        isDirectory: isDirectory,
        deletedAt: DateTime.now(),
        objects: copied,
      );
      await _ossClient.uploadText(
          '$batchRoot' 'manifest.json', entry.encode(), session);
    }
    final deleted = <String>[];
    for (final keys in _batches(copied.keys)) {
      try {
        final result = await _ossClient.deleteMany(keys, session);
        deleted.addAll(result.deletedPaths);
        failed.addAll(result.failedPaths);
      } catch (_) {
        failed.addAll(keys);
      }
    }
    return BatchDeleteSummary(deletedPaths: deleted, failedPaths: failed);
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
    final prefixes =
        await _ossClient.listPrefixes('$rootPrefix.trash/', session);
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
      '$rootPrefix.trash/${entry.id}/manifest.json'
    ])) {
      await _ossClient.deleteMany(keys, session);
    }
    _treeRevision++;
    _clearDirectorySizeCache();
    unawaited(_galleryHooks?.onObjectsRestored(restored.values.toSet()));
    notifyListeners();
  }

  /// 立即删除一个回收批次；对象清单已覆盖批次的全部 payload 对象。
  Future<void> purgeRecycleBinEntry(RecycleBinEntry entry) async {
    await ensureSessionReady();
    final session = _requireSession();
    final failed = <String>[];
    for (final keys in _batches(<String>[
      ...entry.objects.values,
      '$rootPrefix.trash/${entry.id}/manifest.json'
    ])) {
      final result = await _ossClient.deleteMany(keys, session);
      failed.addAll(result.failedPaths);
    }
    if (failed.isNotEmpty) {
      throw AppError('有 ${failed.length} 个对象删除失败，请稍后重试',
          code: 'OSS_DELETE_FAILED');
    }
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

  Future<BatchDeleteSummary> retryBatchDelete(Iterable<String> failedPaths) {
    final paths = failedPaths.toSet();
    return deleteBatch(BatchDeletePreview(
      selectedCount: paths.length,
      directoryCount: 0,
      objectPaths: paths,
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
      _ensureWithinRoot(item.path);
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
    final conflicts = <FileItem>[];
    for (final item in sources) {
      final desired =
          '$targetPrefix${item.name}${item.isDirectory ? '/' : ''}';
      if (await _ossClient.objectExists(desired, session)) {
        conflicts.add(item);
      }
    }
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
    final work = <({String key, String dst})>[];
    for (final pair in plan) {
      final keys = <String>{pair.source};
      if (pair.source.endsWith('/')) {
        keys.addAll(await _ossClient.listAllObjectKeys(pair.source, session));
      }
      for (final key in keys) {
        final dst = key == pair.source
            ? pair.renameRoot
            : '${pair.renameRoot}${key.substring(pair.source.length)}';
        work.add((key: key, dst: dst));
      }
    }
    final failed = <String>[];
    var processed = 0;
    moveStateListenable.value = MoveProgress(processed: 0, total: work.length);
    for (final item in work) {
      try {
        await _ossClient.copy(item.key, item.dst, session);
        await _ossClient.delete(item.key, session);
      } catch (_) {
        // 复制失败可能源于上一轮已完成搬运（源已消失）：目标侧存在且源
        // 已不存在即视为完成；目录标记缺失时改用建目录方式补齐。
        final sourceExists = await _safeObjectExists(item.key, session);
        if (!sourceExists && await _safeObjectExists(item.dst, session)) {
          // 已在上一轮完成。
        } else if (!sourceExists &&
            item.key.endsWith('/') &&
            await _createDirectoryMarker(item.dst, session)) {
          // 空目录标记补齐。
        } else {
          failed.add(item.key);
        }
      }
      processed++;
      moveStateListenable.value =
          MoveProgress(processed: processed, total: work.length);
    }
    return MoveSummary(
      movedCount: work.length - failed.length,
      failedKeys: failed,
      sourceKeys: work.map((item) => item.key).toSet(),
      destinationKeys: work.map((item) => item.dst).toSet(),
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
    final work = <({String key, String dst})>[];
    for (final pair in plan) {
      if (!await _safeObjectExists(pair.renameRoot, session)) {
        // 目标侧不存在：未开始搬运或已被撤销，无需处理。
        continue;
      }
      final keys = <String>{pair.renameRoot};
      if (pair.source.endsWith('/')) {
        keys.addAll(
            await _ossClient.listAllObjectKeys(pair.renameRoot, session));
      }
      for (final key in keys) {
        final relative = key.startsWith(pair.renameRoot) &&
                pair.renameRoot.length > entry.targetPrefix.length
            ? key.substring(pair.renameRoot.length)
            : key.substring(entry.targetPrefix.length);
        var dst = '${pair.source}$relative';
        if (await _safeObjectExists(dst, session)) {
          dst = await _nonConflictingObjectPath(dst, session);
        }
        work.add((key: key, dst: dst));
      }
    }
    _isMoving = true;
    notifyListeners();
    final failed = <String>[];
    try {
      moveStateListenable.value =
          MoveProgress(processed: 0, total: work.length);
      var processed = 0;
      for (final item in work) {
        try {
          await _ossClient.copy(item.key, item.dst, session);
          await _ossClient.delete(item.key, session);
        } catch (_) {
          failed.add(item.key);
        }
        processed++;
        moveStateListenable.value =
            MoveProgress(processed: processed, total: work.length);
      }
      if (failed.isEmpty) {
        try {
          await _ossClient.delete('$_movesRoot${entry.id}/manifest.json',
              session);
        } catch (_) {
          // manifest 删除失败仅残留任务，不影响撤销结果。
        }
      }
    } finally {
      _isMoving = false;
      moveStateListenable.value = null;
      notifyListeners();
    }
    final destinations = work.map((item) => item.dst).toSet();
    _refreshAfterMove(destinations, entry.sourcePrefixes.toSet(),
        MoveSummary(movedCount: work.length - failed.length, failedKeys: failed));
    return MoveSummary(
        movedCount: work.length - failed.length, failedKeys: failed);
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
      _remoteDirectories.removeWhere(
          (path) => path == dir || path.startsWith(dir));
      if (_currentPath.startsWith(dir)) {
        _currentPath = parentPath(dir);
      }
    }
    _remoteDirectories.addAll(addedPrefixes.map(_normalizeDir));
    _treeRevision++;
    _clearDirectorySizeCache();
    if (selectedItemListenable.value != null &&
        removedPrefixes.any((prefix) =>
            selectedItemListenable.value!.path.startsWith(_normalizeDir(prefix)))) {
      selectedItemListenable.value = null;
    }
    clearMultiSelection();
    notifyListeners();
  }

  Future<void> uploadFile(
      {required String fileName,
      required String localPath,
      required int fileSize,
      String? targetPath,
      String? batchId}) async {
    _ensureUploadCapability();
    final dir = _normalizeDir(targetPath ?? _currentPath);
    final taskId = _newTransferId('upload');
    _enqueueTransfer(
      TransferTask(
        id: taskId,
        name: fileName,
        type: TransferTaskType.upload,
        status: TransferTaskStatus.pending,
        progress: 0,
        target: displayPath(dir),
        sourcePath: localPath,
        batchId: batchId,
        totalBytes: fileSize,
      ),
      _QueuedTransfer((report, isCanceled) async {
        if (isCanceled()) throw const TransferCanceledException();
        await ensureSessionReady();
        final session = _requireSession();
        var objectPath = '$dir$fileName';
        // 上传前校验目标是否已存在；放在队列闭包内使重试同样经过校验。
        if (await _ossClient.objectExists(objectPath, session)) {
          final resolution = await _resolveUploadConflict(
            batchId: batchId,
            fileName: fileName,
            targetDisplayPath: displayPath(dir),
          );
          if (isCanceled()) throw const TransferCanceledException();
          switch (resolution) {
            case UploadConflictResolution.skip:
              throw const _UploadSkippedException();
            case UploadConflictResolution.overwrite:
              break;
            case UploadConflictResolution.keepBoth:
              objectPath = await _availableUploadPath(objectPath, session);
          }
        }
        if (isCanceled()) throw const TransferCanceledException();
        // 视频上传前启动截帧，超大图片上传前本地生成缩略图，均与上传
        // 并行准备；失败不影响上传本身。
        Future<String?>? thumbnailFuture;
        final extension = fileName.split('.').last.toLowerCase();
        if (_videoFileExtensions.contains(extension)) {
          thumbnailFuture =
              _galleryHooks?.prepareVideoThumbnail(objectPath, localPath);
        } else if (_imageFileExtensions.contains(extension)) {
          thumbnailFuture =
              _galleryHooks?.prepareImageThumbnail(objectPath, localPath);
        }
        await _ossClient.uploadFile(
          objectPath,
          localPath,
          session,
          taskId: taskId,
          onProgress: report,
        );
        if (isCanceled()) throw const TransferCanceledException();
        _treeRevision++;
        _clearDirectorySizeCache();
        notifyListeners();
        // 上传成功后触发索引增量更新；挂钩异常不影响任务成功状态。
        if (_galleryHooks != null) {
          String? thumbPath;
          try {
            thumbPath = await thumbnailFuture;
          } catch (_) {
            thumbPath = null;
          }
          try {
            await _galleryHooks!.onMediaUploaded(
              objectPath: objectPath,
              localPath: localPath,
              thumbLocalPath: thumbPath,
            );
          } catch (error) {
            debugPrint('[gallery] 索引增量更新挂钩失败: $error');
          }
        }
      }),
    );
  }

  /// 解析上传冲突的处置决策；同批任务通过共享 Completer 保证只弹一次对话框。
  Future<UploadConflictResolution> _resolveUploadConflict({
    required String? batchId,
    required String fileName,
    required String targetDisplayPath,
  }) async {
    final decision = await _requestUploadConflictDecision(
      batchId: batchId,
      fileName: fileName,
      targetDisplayPath: targetDisplayPath,
    );
    return decision.resolution;
  }

  Future<_UploadConflictDecision> _requestUploadConflictDecision({
    required String? batchId,
    required String fileName,
    required String targetDisplayPath,
  }) async {
    if (batchId == null) {
      final result = await _showUploadConflictDialog(
        fileName: fileName,
        targetDisplayPath: targetDisplayPath,
        batchPendingCount: null,
      );
      // 对话框不可用或被系统返回键关闭时按跳过处理，不做覆盖性写入。
      return result ??
          (resolution: UploadConflictResolution.skip, applyToBatch: false);
    }
    final cached = _batchConflictResolutions[batchId];
    if (cached != null) {
      return (resolution: cached, applyToBatch: true);
    }
    final isFirstAsker = !_batchConflictWaiters.containsKey(batchId);
    final waiter = _batchConflictWaiters.putIfAbsent(
      batchId,
      () => Completer<_UploadConflictDecision?>(),
    );
    if (!isFirstAsker) {
      final result = await waiter.future;
      if (result != null) return result;
      // 未勾选整批应用时该批次无统一决策，为当前任务重新询问。
      return _requestUploadConflictDecision(
        batchId: batchId,
        fileName: fileName,
        targetDisplayPath: targetDisplayPath,
      );
    }
    final batchPendingCount = tasks
            .where((task) =>
                task.batchId == batchId &&
                task.status != TransferTaskStatus.success &&
                task.status != TransferTaskStatus.failed &&
                task.status != TransferTaskStatus.canceled)
            .length -
        1;
    final result = await _showUploadConflictDialog(
      fileName: fileName,
      targetDisplayPath: targetDisplayPath,
      batchPendingCount: batchPendingCount <= 0 ? null : batchPendingCount,
    );
    if (result != null && result.applyToBatch) {
      _batchConflictResolutions[batchId] = result.resolution;
    }
    _batchConflictWaiters.remove(batchId);
    waiter.complete(result != null && result.applyToBatch ? result : null);
    return result ??
        (resolution: UploadConflictResolution.skip, applyToBatch: false);
  }

  Future<_UploadConflictDecision?> _showUploadConflictDialog({
    required String fileName,
    required String targetDisplayPath,
    required int? batchPendingCount,
  }) async {
    final context = _navigatorKey?.currentContext;
    if (context == null) return null;
    var selected = UploadConflictResolution.skip;
    var applyToBatch = false;
    return showDialog<_UploadConflictDecision>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: const Text('云端已存在同名文件'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('「$fileName」在「$targetDisplayPath」已存在，请选择处理方式。'),
              RadioGroup<UploadConflictResolution>(
                groupValue: selected,
                onChanged: (value) =>
                    setState(() => selected = value ?? selected),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    RadioListTile<UploadConflictResolution>(
                      title: const Text('保留两者'),
                      subtitle: const Text('自动追加序号后上传，云端原文件保持不变'),
                      value: UploadConflictResolution.keepBoth,
                    ),
                    RadioListTile<UploadConflictResolution>(
                      title: const Text('覆盖'),
                      subtitle: const Text('替换云端已有的同名文件'),
                      value: UploadConflictResolution.overwrite,
                    ),
                    RadioListTile<UploadConflictResolution>(
                      title: const Text('跳过'),
                      subtitle: const Text('不上传，任务直接标记完成'),
                      value: UploadConflictResolution.skip,
                    ),
                  ],
                ),
              ),
              if (batchPendingCount != null)
                CheckboxListTile(
                  value: applyToBatch,
                  onChanged: (value) =>
                      setState(() => applyToBatch = value ?? false),
                  title: Text('同批其余 $batchPendingCount 个文件应用相同处理'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                (resolution: selected, applyToBatch: applyToBatch),
              ),
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
  }

  /// 探测「文件名（1）」样式的可用对象键，用于保留两者上传。
  Future<String> _availableUploadPath(
      String desired, UserSession session) async {
    final directory = parentPath(desired);
    final name = desired.substring(directory.length);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var number = 1;; number++) {
      final candidate = '$directory$stem（$number）$extension';
      if (!await _ossClient.objectExists(candidate, session)) return candidate;
    }
  }

  Future<List<int>> downloadBytes(FileItem item) async {
    if (!capabilities.download) {
      throw StateError('当前身份没有下载权限');
    }
    if (item.isDirectory) {
      throw StateError('一期不支持文件夹下载');
    }

    await ensureSessionReady();
    return _ossClient.download(item.path, _requireSession());
  }

  String enqueueDownload(
    FileItem item, {
    required String targetDirectory,
    String? batchId,
  }) {
    if (!capabilities.download) {
      throw StateError('当前身份没有下载权限');
    }
    if (item.isDirectory) {
      throw StateError('文件夹不支持直接下载');
    }
    _ensureWithinRoot(item.path);
    final taskId = _newTransferId('download');
    _enqueueTransfer(
      TransferTask(
        id: taskId,
        name: item.name,
        type: TransferTaskType.download,
        status: TransferTaskStatus.pending,
        progress: 0,
        target: targetDirectory,
        sourcePath: item.path,
        batchId: batchId,
        totalBytes: item.size,
      ),
      _QueuedTransfer((report, isCanceled) async {
        await ensureSessionReady();
        if (isCanceled()) throw const TransferCanceledException();
        final mediaCollection = _androidMediaCollection(item.name);
        if (mediaCollection != null) {
          await _ossClient.downloadToMediaStore(
            item.path,
            _requireSession(),
            displayName: item.name,
            collection: mediaCollection,
            taskId: taskId,
            onProgress: report,
            isCanceled: isCanceled,
          );
          _replaceTask(taskId, (task) => task.copyWith(target: '系统相册'));
          return;
        }
        if (targetDirectory.startsWith('content://')) {
          await _ossClient.downloadToDirectoryUri(
            item.path,
            _requireSession(),
            directoryUri: targetDirectory,
            displayName: item.name,
            taskId: taskId,
            onProgress: report,
            isCanceled: isCanceled,
          );
          _replaceTask(taskId, (task) => task.copyWith(target: '已选目录'));
          return;
        }
        final destination =
            await _availableDownloadFile(targetDirectory, item.name);
        final temporary = File('${destination.path}.$taskId.part');
        try {
          await _ossClient.downloadToFile(
            item.path,
            _requireSession(),
            temporary,
            taskId: taskId,
            onProgress: report,
            isCanceled: isCanceled,
          );
          if (isCanceled()) throw const TransferCanceledException();
          await temporary.rename(destination.path);
          _replaceTask(
              taskId, (task) => task.copyWith(target: destination.path));
        } catch (_) {
          if (await temporary.exists()) await temporary.delete();
          rethrow;
        }
      }),
    );
    return taskId;
  }

  /// 相册原图按需下载：写入相册专用缓存目录，完成后由回调写入缓存记录。
  /// 走现有传输队列，进度、取消与重试与普通下载一致。
  String enqueueOriginalDownload({
    required String path,
    required String name,
    required int? totalBytes,
    required File target,
    required Future<void> Function(File target) onCompleted,
  }) {
    if (!capabilities.download) {
      throw StateError('当前身份没有下载权限');
    }
    _ensureWithinRoot(path);
    final taskId = _newTransferId('download');
    _enqueueTransfer(
      TransferTask(
        id: taskId,
        name: name,
        type: TransferTaskType.download,
        status: TransferTaskStatus.pending,
        progress: 0,
        target: '相册缓存',
        sourcePath: path,
        totalBytes: totalBytes,
      ),
      _QueuedTransfer((report, isCanceled) async {
        await ensureSessionReady();
        if (isCanceled()) throw const TransferCanceledException();
        final temporary = File('${target.path}.$taskId.part');
        try {
          await _ossClient.downloadToFile(
            path,
            _requireSession(),
            temporary,
            taskId: taskId,
            onProgress: report,
            isCanceled: isCanceled,
          );
          if (isCanceled()) throw const TransferCanceledException();
          await temporary.rename(target.path);
          await onCompleted(target);
        } catch (_) {
          if (await temporary.exists()) await temporary.delete();
          rethrow;
        }
      }),
    );
    return taskId;
  }

  String enqueueDownloads(Iterable<FileItem> items,
      {required String targetDirectory}) {
    final batchId = 'batch-${DateTime.now().microsecondsSinceEpoch}';
    for (final item in items.where((item) => !item.isDirectory)) {
      enqueueDownload(item, targetDirectory: targetDirectory, batchId: batchId);
    }
    return batchId;
  }

  /// 递归展开选中的文件夹，并将每个文件作为独立下载任务入队。
  ///
  /// 目录中的文件按其相对于当前文件视图的路径保存，避免拍平目录结构。
  Future<BatchDownloadEnqueueResult> enqueueDownloadsRecursively(
    Iterable<FileItem> items, {
    required String targetDirectory,
  }) async {
    if (!capabilities.download) {
      throw StateError('当前身份没有下载权限');
    }
    final selected = items.toList(growable: false);
    final targets = <String, _DownloadTarget>{};
    await ensureSessionReady();
    final session = _requireSession();

    for (final item in selected.where((item) => item.isDirectory)) {
      _ensureWithinRoot(item.path);
      final keys = await _ossClient.listAllObjectKeys(item.path, session);
      for (final key in keys.where((key) => !key.endsWith('/'))) {
        _ensureWithinRoot(key);
        targets.putIfAbsent(
          key,
          () => _DownloadTarget(
            item: FileItem(
              path: key,
              name: _fileName(key),
              isDirectory: false,
            ),
            targetDirectory: _downloadDirectoryFor(key, targetDirectory),
          ),
        );
      }
    }
    for (final item in selected.where((item) => !item.isDirectory)) {
      _ensureWithinRoot(item.path);
      targets.putIfAbsent(
        item.path,
        () => _DownloadTarget(item: item, targetDirectory: targetDirectory),
      );
    }

    final batchId = 'batch-${DateTime.now().microsecondsSinceEpoch}';
    for (final target in targets.values) {
      enqueueDownload(
        target.item,
        targetDirectory: target.targetDirectory,
        batchId: batchId,
      );
    }
    return BatchDownloadEnqueueResult(
      batchId: batchId,
      fileCount: targets.length,
      directoryCount: selected.where((item) => item.isDirectory).length,
    );
  }

  Future<void> setTransferConcurrency(int value) async {
    final normalized = value.clamp(
      _minTransferConcurrency,
      _maxTransferConcurrency,
    );
    if (normalized == transferConcurrency) return;
    transferConcurrencyListenable.value = normalized;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(_transferConcurrencyKey, normalized);
    } catch (_) {
      // 设置立即生效；偏好写入失败时不阻断当前传输。
    }
    _drainTransferQueue();
  }

  void retryTask(String taskId) {
    final task = tasks.where((item) => item.id == taskId).firstOrNull;
    if (task == null ||
        (task.status != TransferTaskStatus.failed &&
            task.status != TransferTaskStatus.canceled)) {
      return;
    }
    if (!_queuedTransfers.containsKey(taskId)) {
      // 兼容应用恢复前遗留或测试注入的任务；真实任务均有执行器。
      _replaceTask(
          taskId,
          (value) => value.copyWith(
                status: TransferTaskStatus.running,
                progress: 0,
                message: '重新开始',
              ));
      return;
    }
    _canceledTransferIds.remove(taskId);
    _replaceTask(
        taskId,
        (value) => value.copyWith(
              status: TransferTaskStatus.pending,
              progress: 0,
              transferredBytes: 0,
              message: '重新开始',
            ));
    _pendingTransferIds.add(taskId);
    _drainTransferQueue();
  }

  /// 对已失败或已取消的任务重新排队。
  void retryTasks(Iterable<String> taskIds) {
    for (final taskId in taskIds.toSet()) {
      retryTask(taskId);
    }
  }

  void cancelTask(String taskId) {
    final task = tasks.where((item) => item.id == taskId).firstOrNull;
    if (task == null ||
        (task.status != TransferTaskStatus.running &&
            task.status != TransferTaskStatus.pending)) {
      return;
    }
    _pendingTransferIds.remove(taskId);
    _canceledTransferIds.add(taskId);
    if (task.status == TransferTaskStatus.running) {
      unawaited(_ossClient.cancelTransfer(taskId));
    }
    _replaceTask(
        taskId,
        (value) => value.copyWith(
              status: TransferTaskStatus.canceled,
              message: '已取消',
            ));
  }

  /// 取消正在等待或执行中的任务。
  void cancelTasks(Iterable<String> taskIds) {
    for (final taskId in taskIds.toSet()) {
      cancelTask(taskId);
    }
  }

  void clearCompletedTasks() {
    _setTasks(
      tasksListenable.value
          .where(
            (task) =>
                task.status != TransferTaskStatus.success &&
                task.status != TransferTaskStatus.canceled,
          )
          .toList(),
    );
  }

  void prepareShareImport({List<ShareImportItem>? items, String? targetPath}) {
    _pendingShareItems = List<ShareImportItem>.unmodifiable(
      items ?? const <ShareImportItem>[],
    );
    _shareTargetPath = _normalizeDir(targetPath ?? rootPrefix);
    notifyListeners();
  }

  void setShareTargetPath(String path) {
    _shareTargetPath = _normalizeDir(path);
    notifyListeners();
  }

  Future<void> confirmShareUpload() async {
    _ensureUploadCapability();
    if (_pendingShareItems.isEmpty) {
      throw StateError('没有待上传内容');
    }
    final items = _pendingShareItems;
    for (final item in items) {
      if (item.localPath.isEmpty || !await File(item.localPath).exists()) {
        throw StateError('分享文件“${item.name}”已不可用，请重新分享');
      }
    }
    _pendingShareItems = const <ShareImportItem>[];
    notifyListeners();
    // 多文件分享导入归属同一批次，传输中心可展示整批上传汇总。
    final batchId = items.length > 1
        ? 'batch-${DateTime.now().microsecondsSinceEpoch}'
        : null;
    for (final item in items) {
      await uploadFile(
        fileName: item.name,
        localPath: item.localPath,
        fileSize: item.size,
        targetPath: _shareTargetPath,
        batchId: batchId,
      );
    }
  }

  List<String> get sidebarDirectories {
    if (_session?.isRemote == true) {
      final root = _normalizeDir(_session?.rootPrefix ?? rootPrefix);
      final dirs = _remoteDirectories.where((path) {
        if (!path.startsWith(root)) return false;
        final rest = path.substring(root.length);
        return rest.isNotEmpty && rest.indexOf('/') == rest.length - 1;
      }).toList()
        ..sort();
      return List<String>.unmodifiable(dirs);
    }
    return const <String>[];
  }

  void _enqueueTransfer(TransferTask task, _QueuedTransfer transfer) {
    _queuedTransfers[task.id] = transfer;
    _setTasks(<TransferTask>[...tasks, task]);
    _pendingTransferIds.add(task.id);
    _drainTransferQueue();
  }

  void _drainTransferQueue() {
    while (_runningTransferIds.length < transferConcurrency &&
        _pendingTransferIds.isNotEmpty) {
      final taskId = _pendingTransferIds.removeAt(0);
      final task = tasks.where((item) => item.id == taskId).firstOrNull;
      if (task == null || task.status != TransferTaskStatus.pending) continue;
      _runningTransferIds.add(taskId);
      unawaited(_runTransfer(taskId));
    }
  }

  Future<void> _runTransfer(String taskId) async {
    final queued = _queuedTransfers[taskId];
    if (queued == null) return;
    _replaceTask(
        taskId,
        (task) => task.copyWith(
              status: TransferTaskStatus.running,
              message: '进行中',
            ));
    final speedTracker = _TransferSpeedTracker();
    var lastUiUpdate = Duration.zero;
    try {
      await queued.run(
        (received, total) {
          final now = speedTracker.elapsed;
          final isFinalBytes = total != null && total > 0 && received >= total;
          final speed = speedTracker.update(received);
          if (!isFinalBytes &&
              now - lastUiUpdate < const Duration(milliseconds: 100)) {
            return;
          }
          lastUiUpdate = now;
          final progress = total == null || total == 0
              ? 0.0
              : (received / total).clamp(0.0, 1.0);
          _replaceTask(
              taskId,
              (task) => task.copyWith(
                    progress: progress,
                    transferredBytes: received,
                    totalBytes: total,
                    bytesPerSecond: speed,
                    message: isFinalBytes ? '正在确认' : '进行中',
                  ));
        },
        () => _canceledTransferIds.contains(taskId),
      );
      if (_canceledTransferIds.contains(taskId)) {
        _replaceTask(
            taskId,
            (task) => task.copyWith(
                  status: TransferTaskStatus.canceled,
                  message: '已取消',
                ));
      } else {
        _replaceTask(
            taskId,
            (task) => task.copyWith(
                  status: TransferTaskStatus.success,
                  progress: 1,
                  bytesPerSecond: null,
                  message: '已完成',
                ));
      }
    } on TransferCanceledException {
      _replaceTask(
          taskId,
          (task) => task.copyWith(
                status: TransferTaskStatus.canceled,
                message: '已取消',
              ));
    } on _UploadSkippedException {
      _replaceTask(
          taskId,
          (task) => task.copyWith(
                status: TransferTaskStatus.success,
                progress: 1,
                bytesPerSecond: null,
                message: '已存在，跳过',
              ));
    } catch (error) {
      _replaceTask(
          taskId,
          (task) => task.copyWith(
                status: TransferTaskStatus.failed,
                message: '失败',
                error: error.toString().replaceFirst('Bad state: ', ''),
              ));
    } finally {
      _runningTransferIds.remove(taskId);
      _canceledTransferIds.remove(taskId);
      _drainTransferQueue();
    }
  }

  void _replaceTask(
    String taskId,
    TransferTask Function(TransferTask task) transform,
  ) {
    final current = List<TransferTask>.from(tasks);
    final index = current.indexWhere((task) => task.id == taskId);
    if (index < 0) return;
    current[index] = transform(current[index]);
    _setTasks(current);
  }

  String _newTransferId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_nextTransferId++}';

  Future<File> _availableDownloadFile(String directory, String name) async {
    final slash = Platform.pathSeparator;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var index = 0;; index++) {
      final suffix = index == 0 ? '' : ' ($index)';
      final candidate = File('$directory$slash$base$suffix$extension');
      if (!await candidate.exists()) return candidate;
    }
  }

  String _downloadDirectoryFor(String objectPath, String targetDirectory) {
    final relative = objectPath.startsWith(_currentPath)
        ? objectPath.substring(_currentPath.length)
        : objectPath;
    final segments =
        relative.split('/').where((segment) => segment.isNotEmpty).toList();
    if (segments.length < 2) return targetDirectory;
    return <String>[
      targetDirectory,
      ...segments.take(segments.length - 1),
    ].join(Platform.pathSeparator);
  }

  String? _androidMediaCollection(String fileName) {
    if (!Platform.isAndroid) return null;
    final extension = fileName.split('.').last.toLowerCase();
    if (const <String>{'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'}
        .contains(extension)) {
      return 'images';
    }
    if (const <String>{'mp4', 'mov', 'mkv', 'avi', 'webm', '3gp'}
        .contains(extension)) {
      return 'video';
    }
    return null;
  }

  String _fileName(String path) {
    final normalized =
        path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  void _ensureWithinRoot(String path) {
    final root = _normalizeDir(_session?.rootPrefix ?? rootPrefix);
    if (!path.startsWith(root)) {
      throw StateError('文件路径不在当前共享空间内');
    }
  }

  void _setTasks(List<TransferTask> next) {
    tasksListenable.value = List<TransferTask>.unmodifiable(next);
    _saveTransferHistory();
  }

  void _restoreTransferHistory(SharedPreferences preferences) {
    final rawHistory = preferences.getString(_transferHistoryKey);
    if (rawHistory == null) return;
    try {
      final decoded = jsonDecode(rawHistory);
      if (decoded is! List) return;
      final history = decoded
          .whereType<Map>()
          .map((item) => TransferTask.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
              ))
          .whereType<TransferTask>()
          .where(_isHistoricalTransferTask)
          .toList(growable: false);
      tasksListenable.value = List<TransferTask>.unmodifiable(history);
    } catch (_) {
      // 本地历史损坏时忽略，避免影响应用启动。
    }
  }

  bool _isHistoricalTransferTask(TransferTask task) {
    return task.status == TransferTaskStatus.success ||
        task.status == TransferTaskStatus.canceled;
  }

  void _saveTransferHistory() {
    if (!_transferHistoryReady) return;
    _transferHistoryDirty = true;
    if (_isSavingTransferHistory) return;
    _isSavingTransferHistory = true;
    unawaited(_persistTransferHistory());
  }

  Future<void> _persistTransferHistory() async {
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      while (_transferHistoryDirty) {
        _transferHistoryDirty = false;
        final history = tasks.where(_isHistoricalTransferTask).toList();
        await preferences.setString(
          _transferHistoryKey,
          jsonEncode(history.map((task) => task.toJson()).toList()),
        );
      }
    } catch (_) {
      // 历史记录写入失败不影响当前传输。
    } finally {
      _isSavingTransferHistory = false;
      if (_transferHistoryDirty) _saveTransferHistory();
    }
  }

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

  String _normalizeDir(String path) {
    if (path.isEmpty) {
      return rootPrefix;
    }
    return path.endsWith('/') ? path : '$path/';
  }

  @override
  void dispose() {
    _canceledTransferIds.addAll(_runningTransferIds);
    for (final taskId in _runningTransferIds) {
      unawaited(_ossClient.cancelTransfer(taskId));
    }
    selectedItemListenable.dispose();
    multiSelectedPathsListenable.dispose();
    directorySizeStatesListenable.dispose();
    moveStateListenable.dispose();
    tasksListenable.dispose();
    transferConcurrencyListenable.dispose();
    super.dispose();
  }
}

class _TransferSpeedTracker {
  final Stopwatch _watch = Stopwatch()..start();
  final List<(Duration, int)> _samples = <(Duration, int)>[];
  double? _previousSpeed;

  Duration get elapsed => _watch.elapsed;

  double? update(int bytes) {
    final now = _watch.elapsed;
    _samples.add((now, bytes));
    final cutoff = now - const Duration(seconds: 2);
    while (_samples.length > 2 && _samples[1].$1 < cutoff) {
      _samples.removeAt(0);
    }
    final first = _samples.first;
    final elapsedMicros = (now - first.$1).inMicroseconds;
    if (elapsedMicros < const Duration(milliseconds: 100).inMicroseconds) {
      return _previousSpeed;
    }
    final delta = bytes - first.$2;
    if (delta < 0) return _previousSpeed;
    final speed = delta * Duration.microsecondsPerSecond / elapsedMicros;
    _previousSpeed = speed;
    return speed;
  }
}

class _DownloadTarget {
  const _DownloadTarget({required this.item, required this.targetDirectory});

  final FileItem item;
  final String targetDirectory;
}

typedef _TransferProgressReporter = void Function(int received, int? total);

class _QueuedTransfer {
  const _QueuedTransfer(this.run);

  final Future<void> Function(
    _TransferProgressReporter report,
    bool Function() isCanceled,
  ) run;
}
