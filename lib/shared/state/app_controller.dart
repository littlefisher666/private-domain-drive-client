import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/errors/app_error.dart';
import '../../features/auth/domain/user_session.dart';
import '../../features/auth/infrastructure/session_repository.dart';
import '../../features/transfer/domain/transfer_task.dart';
import '../../features/workspace/domain/file_item.dart';
import '../../features/workspace/domain/recycle_bin_entry.dart';
import '../../features/workspace/infrastructure/oss_client.dart';

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

class DirectorySizeState {
  const DirectorySizeState._({this.size, required this.isLoading});

  const DirectorySizeState.loading() : this._(isLoading: true);

  const DirectorySizeState.ready(int size)
      : this._(size: size, isLoading: false);

  const DirectorySizeState.failed() : this._(isLoading: false);

  final int? size;
  final bool isLoading;
}

class TransferBatchSummary {
  const TransferBatchSummary({
    required this.id,
    required this.total,
    required this.pending,
    required this.running,
    required this.success,
    required this.failed,
  });

  final String id;
  final int total;
  final int pending;
  final int running;
  final int success;
  final int failed;
}

/// 应用状态控制器。会话与权限来自已部署的 FC，不在生产路径伪造身份。
class AppController extends ChangeNotifier {
  AppController(
      {required SessionRepository sessionRepository, OssClient? ossClient})
      : _sessionRepository = sessionRepository,
        _ossClient = ossClient ?? OssClient();

  final SessionRepository _sessionRepository;
  final OssClient _ossClient;

  static const rootPrefix = 'shared/';
  static const _transferConcurrencyKey = 'transfer_concurrency';
  static const _transferHistoryKey = 'transfer_history:v1';
  static const _fileSortOptionKey = 'file_sort_option';
  static const _fileSortOptionsByDirectoryKey =
      'file_sort_options_by_directory';
  static const _themeModeKey = 'theme_mode';
  static const _thumbnailSizeKey = 'thumbnail_size';
  static const _takenAtCachePrefix = 'image_taken_at:v5:';
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

  UserSession? _session;
  String _currentPath = rootPrefix;
  BrowseMode _browseMode = BrowseMode.list;
  ThumbnailSize _thumbnailSize = ThumbnailSize.medium;
  FileSortOption _defaultFileSortOption = FileSortOption.updatedNewest;
  final Map<String, FileSortOption> _fileSortOptionsByDirectory =
      <String, FileSortOption>{};
  final Set<String> _remoteDirectories = <String>{};
  List<ShareImportItem> _pendingShareItems = const <ShareImportItem>[];
  String _shareTargetPath = 'shared/photos/';
  bool _bootstrapped = false;
  ThemeMode _themeMode = ThemeMode.light;
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
  List<TransferBatchSummary> get transferBatches {
    final grouped = <String, List<TransferTask>>{};
    for (final task in tasks) {
      final batchId = task.batchId;
      if (batchId != null) (grouped[batchId] ??= <TransferTask>[]).add(task);
    }
    return grouped.entries.map((entry) {
      final values = entry.value;
      int count(TransferTaskStatus status) =>
          values.where((task) => task.status == status).length;
      return TransferBatchSummary(
        id: entry.key,
        total: values.length,
        pending: count(TransferTaskStatus.pending),
        running: count(TransferTaskStatus.running),
        success: count(TransferTaskStatus.success),
        failed: count(TransferTaskStatus.failed),
      );
    }).toList(growable: false);
  }

  List<ShareImportItem> get pendingShareItems =>
      List<ShareImportItem>.unmodifiable(_pendingShareItems);
  String get shareTargetPath => _shareTargetPath;
  FileItem? get selectedItem => selectedItemListenable.value;
  bool get isMultiSelectionMode => _isMultiSelectionMode;
  int get multiSelectedCount => multiSelectedPathsListenable.value.length;
  Set<String> get multiSelectedPaths => multiSelectedPathsListenable.value;
  bool get bootstrapped => _bootstrapped;
  ThemeMode get themeMode => _themeMode;
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
      _transferHistoryReady = true;
    } catch (_) {
      // 偏好读取失败不应阻断会话恢复。
    }
    try {
      final restored = await _sessionRepository.restore();
      if (restored != null) {
        _session = restored;
        _currentPath =
            restored.rootPrefix.isEmpty ? rootPrefix : restored.rootPrefix;
        if (restored.isRemote && restored.credentials != null) {
          await _ossClient.configureSession(restored);
        }
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
      if (session.isRemote && session.credentials != null) {
        await _ossClient.configureSession(session);
      }
      selectedItemListenable.value = null;
      _clearDirectorySizeCache();
      notifyListeners();
      return LoginResult.success(session);
    } on AppError catch (error) {
      return LoginResult.failure(error.message);
    } catch (error) {
      return LoginResult.failure(error.toString());
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
      notifyListeners();
      return null;
    } on AppError catch (error) {
      return error.message;
    } catch (error) {
      return error.toString();
    }
  }

  Future<void> ensureFreshCredentials({bool force = false}) async {
    final session = _session;
    if (session == null || !session.isRemote) {
      return;
    }
    final credentials = session.credentials;
    if (!force &&
        credentials != null &&
        credentials.isValid(skew: const Duration(minutes: 8))) {
      return;
    }
    final refreshed = await _sessionRepository.refreshCredentials(session);
    _session = refreshed;
    await _ossClient.configureSession(refreshed);
    notifyListeners();
  }

  UserSession _requireSession() {
    final session = _session;
    if (session == null || !session.isRemote || session.credentials == null) {
      throw AppError('请先登录服务端账号', code: 'REMOTE_SESSION_REQUIRED');
    }
    return session;
  }

  Future<List<FileItem>> listDirectory([String? path]) async {
    final session = _session;
    if (session == null || !session.isRemote || session.credentials == null) {
      throw AppError('请先登录服务端账号', code: 'REMOTE_SESSION_REQUIRED');
    }
    await ensureFreshCredentials();
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
    await ensureFreshCredentials();
    return _ossClient.downloadThumbnail(item.path, _session ?? session);
  }

  Future<List<int>> loadImagePreview(FileItem item) async {
    if (item.isDirectory || item.kind != FileKind.image) {
      throw StateError('只有图片文件支持在线预览');
    }
    final session = _requireSession();
    await ensureFreshCredentials();
    return _ossClient.downloadImagePreview(item.path, _session ?? session);
  }

  String get thumbnailCacheNamespace {
    final session = _session;
    final bucket = session?.ossConfig?.bucket ?? '';
    return '$bucket|${session?.userId ?? ''}';
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
      takenAt = await _ossClient.readImageTakenAt(item.path, session);
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
      await ensureFreshCredentials();
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
    await ensureFreshCredentials();
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
    await ensureFreshCredentials();
    final session = _requireSession();
    await _ossClient.copy(item.path, newPath, session);
    await _ossClient.delete(item.path, session);
    _treeRevision++;
    _clearDirectorySizeCache();
    notifyListeners();
  }

  Future<void> deleteItem(FileItem item) async {
    _ensureDeleteCapability();
    await ensureFreshCredentials();
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
    notifyListeners();
  }

  Future<BatchDeletePreview> prepareBatchDelete(
    Iterable<FileItem> items,
  ) async {
    _ensureDeleteCapability();
    final selected = items.toList(growable: false);
    final paths = <String>{};
    await ensureFreshCredentials();
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
    await ensureFreshCredentials();
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
    await ensureFreshCredentials();
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
    await ensureFreshCredentials();
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

  Future<void> uploadFile(
      {required String fileName,
      required String localPath,
      required int fileSize,
      String? targetPath}) async {
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
        totalBytes: fileSize,
      ),
      _QueuedTransfer((report, isCanceled) async {
        if (isCanceled()) throw const TransferCanceledException();
        await ensureFreshCredentials();
        await _ossClient.uploadFile(
          '$dir$fileName',
          localPath,
          _requireSession(),
          taskId: taskId,
          onProgress: report,
        );
        if (isCanceled()) throw const TransferCanceledException();
        _treeRevision++;
        _clearDirectorySizeCache();
        notifyListeners();
      }),
    );
  }

  Future<List<int>> downloadBytes(FileItem item) async {
    if (!capabilities.download) {
      throw StateError('当前身份没有下载权限');
    }
    if (item.isDirectory) {
      throw StateError('一期不支持文件夹下载');
    }

    await ensureFreshCredentials();
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
        await ensureFreshCredentials();
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
    await ensureFreshCredentials();
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

  void cancelBatch(String batchId) {
    cancelTasks(
      tasks.where((task) => task.batchId == batchId).map((task) => task.id),
    );
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
    _shareTargetPath = _normalizeDir(targetPath ?? 'shared/photos/');
    notifyListeners();
  }

  void removeShareItem(String id) {
    _pendingShareItems = _pendingShareItems
        .where((item) => item.id != id)
        .toList(growable: false);
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
    for (final item in items) {
      await uploadFile(
        fileName: item.name,
        localPath: item.localPath,
        fileSize: item.size,
        targetPath: _shareTargetPath,
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
