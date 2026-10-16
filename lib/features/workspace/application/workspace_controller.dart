import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/errors/app_error.dart';
import '../../../shared/cache/disk_document_cache.dart';
import '../../../shared/cache/disk_image_cache.dart';
import '../../../shared/path_utils.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/user_session.dart';
import '../../preview/infrastructure/text_preview_loader.dart';
import '../domain/directory_alias.dart';
import '../domain/file_item.dart';
import '../infrastructure/alias_repository.dart';
import '../infrastructure/directory_summary_service.dart';
import '../infrastructure/oss_client.dart';

part 'workspace_controller_listing.dart';
part 'workspace_controller_media.dart';
part 'workspace_controller_selection.dart';

/// 工作区域控制器：目录浏览与导航、条目选择、创建/重命名、
/// 排序与缩略图偏好、目录统计摘要与媒体加载。
///
/// Dart 不允许把同一个类拆到多个 part 文件，因此按职责拆出的成员以
/// mixin 形式放在 `workspace_controller_listing.dart`（目录列举与
/// 统计摘要、创建/重命名）、`workspace_controller_media.dart`
/// （媒体加载）与 `workspace_controller_selection.dart`（选择与
/// 目录大小）中，由 [WorkspaceController] 混入，公开 API 与行为
/// 不变；主文件保留字段、导航核心与跨 part 共用的基础方法。
class WorkspaceController extends _WorkspaceControllerCore
    with
        _WorkspaceControllerListing,
        _WorkspaceControllerMedia,
        _WorkspaceControllerSelection {
  WorkspaceController({
    required super.sessionController,
    required super.ossClient,
  });

  /// 会话变更后的跨域复位：路径、浏览树、选择与统计缓存。
  void handleSessionChanged() {
    final session = _sessionController.session;
    if (session != null) {
      _currentPath =
          session.rootPrefix.isEmpty ? rootPrefix : session.rootPrefix;
    }
    _directorySummaryService.bumpGeneration();
    _remoteDirectories.clear();
    selectedItemListenable.value = null;
    clearDirectorySizeCache();
    clearMultiSelection();
  }

  // ---------- 导航 / 别名 ----------

  void setCurrentPath(String path) {
    _currentPath = normalizeDirPath(path);
    // 任意路径切换都脱离别名上下文；进入别名走 openAlias。
    _activeAliasName = null;
    _aliasReturnPath = null;
    selectedItemListenable.value = null;
    clearMultiSelection();
    notifyListeners();
  }

  /// 内部修正当前路径而不触发用户导航语义：不清除别名上下文与选择。
  void replaceCurrentPath(String path) {
    _currentPath = normalizeDirPath(path);
  }

  /// 进入虚拟目录别名：设置目标前缀与别名上下文并复位选择。
  void enterAliasTarget({
    required String targetPrefix,
    required String aliasName,
    String? returnPath,
  }) {
    _currentPath = targetPrefix;
    _activeAliasName = aliasName;
    _aliasReturnPath = returnPath;
    selectedItemListenable.value = null;
    clearMultiSelection();
    notifyListeners();
  }

  /// 别名重命名后同步当前展示名称（仅当正在展示该别名时）。
  void renameActiveAlias(String oldName, String newName) {
    if (_activeAliasName == oldName) {
      _activeAliasName = newName;
    }
  }

  /// 别名写入完成后由 [AliasController] 回写本地缓存：读-改-写经别名
  /// 仓库完成；树版本、目录大小缓存与通知由调用方按各自语义决定
  /// （创建/删除/重命名不同）。
  void adoptAliasTable(DirectoryAliasTable table) {
    _aliasTable = table;
  }

  // ---------- 创建 / 重命名 ----------

  Future<void> createFolder(String name, {String? targetPath}) async {
    _sessionController.ensureUploadCapability();
    final folderName = name.trim();
    if (folderName.isEmpty) {
      throw StateError('文件夹名称不能为空');
    }
    final dir = normalizeDirPath(targetPath ?? _currentPath);
    final path = '$dir$folderName/';
    await _sessionController.ensureSessionReady();
    await _ossClient.createFolder(path, _sessionController.requireSession());
    _directorySummaryService.noteFilesAdded(dir, 1, DateTime.now());
    calibrateDirectorySummary(dir);
    clearDirectorySizeCache();
    _treeRevision++;
    notifyListeners();
  }

  Future<void> renameItem(FileItem item, String newName) async {
    // rename treated as write capability with delete/upload
    _sessionController.ensureDeleteCapability();
    if (!_sessionController.capabilities.upload &&
        !_sessionController.capabilities.delete) {
      throw StateError('当前身份没有重命名权限');
    }
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      throw StateError('名称不能为空');
    }

    final parent = parentPathOf(item.path);
    final dir = normalizeDirPath(parent == item.path ? rootPrefix : parent);
    final newPath = item.isDirectory ? '$dir$trimmed/' : '$dir$trimmed';
    await _sessionController.ensureSessionReady();
    final session = _sessionController.requireSession();
    await _ossClient.copy(item.path, newPath, session);
    await _ossClient.delete(item.path, session);
    if (item.isDirectory) {
      // 目录改名等价于移动，旧路径统计失效、新路径由校准重建。
      _directorySummaryService.invalidate(item.path);
      _directorySummaryService.invalidate(newPath);
      calibrateDirectorySummary(newPath);
    }
    _treeRevision++;
    clearDirectorySizeCache();
    notifyListeners();
  }
}

/// WorkspaceController 的核心：字段、构造与各 part 共用的基础方法
/// （会话/路径展示、排序与缩略图偏好、EXIF 拍摄时间解析、浏览树维护）。
abstract class _WorkspaceControllerCore extends ChangeNotifier {
  _WorkspaceControllerCore({
    required SessionController sessionController,
    required OssClient ossClient,
  })  : _sessionController = sessionController,
        _ossClient = ossClient,
        _directorySummaryService = DirectorySummaryService(
          ossClient: ossClient,
          sessionProvider: () => sessionController.session,
        ) {
    _aliasRepository = AliasRepository(ossClient: ossClient);
  }

  final SessionController _sessionController;
  final OssClient _ossClient;
  final DirectorySummaryService _directorySummaryService;
  late final AliasRepository _aliasRepository;

  static const _fileSortOptionKey = 'file_sort_option';
  static const _fileSortOptionsByDirectoryKey =
      'file_sort_options_by_directory';
  static const _thumbnailSizeKey = 'thumbnail_size';
  static const _takenAtCachePrefix = 'image_taken_at:v5:';

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

  String _currentPath = rootPrefix;

  /// 最近一次加载的别名表；根目录浏览与别名写入时刷新。
  DirectoryAliasTable _aliasTable = const DirectoryAliasTable();

  /// 经「进入别名」到达当前目录时记录的别名名称；任意路径切换即清除。
  /// 用于标题展示与「别名根层级后退返回根目录」语义。
  String? _activeAliasName;

  /// 进入别名前的所在层级，别名根层级后退返回该位置（挂载层级）。
  String? _aliasReturnPath;
  BrowseMode _browseMode = BrowseMode.list;
  ThumbnailSize _thumbnailSize = ThumbnailSize.medium;
  FileSortOption _defaultFileSortOption = FileSortOption.updatedNewest;
  final Map<String, FileSortOption> _fileSortOptionsByDirectory =
      <String, FileSortOption>{};
  final Set<String> _remoteDirectories = <String>{};
  int _treeRevision = 0;
  bool _isMultiSelectionMode = false;
  String? _selectionAnchorPath;
  SharedPreferences? _preferences;

  String get currentPath => _currentPath;

  /// 当前会话的工作区根目录，供目录选择器等需要全树导航的场景使用。
  String get workspaceRoot {
    final session = _sessionController.session;
    return session?.rootPrefix.isNotEmpty == true
        ? normalizeDirPath(session!.rootPrefix)
        : rootPrefix;
  }

  int get treeRevision => _treeRevision;

  /// 将 OSS 内部对象键转换为用户可见的相对路径。
  String displayPath(String path) {
    final normalized = path.trim();
    final session = _sessionController.session;
    final root = session?.rootPrefix.isNotEmpty == true
        ? normalizeDirPath(session!.rootPrefix)
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

  /// 工作区标题：经别名进入且仍在别名根层级时显示别名名称。
  String get currentTitle =>
      _activeAliasName ?? displayPath(_currentPath);

  /// 后退目标目录；处于别名根层级时返回进入前的挂载层级，已在根目录返回 null。
  String? backNavigationPath() {
    final current = normalizeDirPath(_currentPath);
    final root = normalizeDirPath(workspaceRoot);
    if (current == root) return null;
    if (_activeAliasName != null) {
      final returnPath = _aliasReturnPath;
      if (returnPath != null &&
          normalizeDirPath(returnPath) != current &&
          normalizeDirPath(returnPath).startsWith(root)) {
        return normalizeDirPath(returnPath);
      }
      return root;
    }
    return parentPathOf(current);
  }

  /// 当前已加载的别名条目，供名称冲突校验与目录选择器复用。
  List<DirectoryAlias> get directoryAliases => _aliasTable.aliases;

  /// 当前别名表（含按 id 查询等能力），供别名控制器读写。
  DirectoryAliasTable get aliasTable => _aliasTable;

  String? get activeAliasName => _activeAliasName;

  BrowseMode get browseMode => _browseMode;
  ThumbnailSize get thumbnailSize => _thumbnailSize;
  FileSortOption get fileSortOption => _fileSortOptionForPath(_currentPath);

  FileItem? get selectedItem => selectedItemListenable.value;
  bool get isMultiSelectionMode => _isMultiSelectionMode;
  int get multiSelectedCount => multiSelectedPathsListenable.value.length;
  Set<String> get multiSelectedPaths => multiSelectedPathsListenable.value;

  List<String> get sidebarDirectories {
    final session = _sessionController.session;
    if (session?.isRemote == true) {
      final root = normalizeDirPath(session?.rootPrefix ?? rootPrefix);
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

  String get thumbnailCacheNamespace {
    final session = _sessionController.session;
    final bucket = session?.ossConfig?.bucket ?? '';
    return '$bucket|${session?.userId ?? ''}';
  }

  // ---------- 偏好 ----------

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

  /// 启动恢复排序与缩略图偏好。
  void restorePreferences(SharedPreferences preferences) {
    _preferences = preferences;
    _restoreSortPreferences(preferences);
    _restoreThumbnailSize(preferences);
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
    final session = _sessionController.session;
    final bucket = session?.ossConfig?.bucket ?? '';
    final userId = session?.userId ?? '';
    return '$bucket:$userId:${normalizeDirPath(path)}';
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

  // ---------- 浏览树维护 ----------

  /// 记录新出现的可浏览目录（已规范化）。
  void addBrowsedDirectories(Iterable<String> prefixes) {
    _remoteDirectories.addAll(prefixes.map(normalizeDirPath));
  }

  /// 按谓词移除可浏览目录。
  void removeBrowsedDirectoriesWhere(bool Function(String path) test) {
    _remoteDirectories.removeWhere(test);
  }

  /// 树结构变更计数（供依赖方感知目录列表需要刷新）。
  void bumpTreeRevision() {
    _treeRevision++;
  }

  /// 校验路径位于当前共享空间根内。
  void ensureWithinRoot(String path) {
    final root = normalizeDirPath(
        _sessionController.session?.rootPrefix ?? rootPrefix);
    if (!path.startsWith(root)) {
      throw StateError('文件路径不在当前共享空间内');
    }
  }

  @override
  void dispose() {
    selectedItemListenable.dispose();
    multiSelectedPathsListenable.dispose();
    directorySizeStatesListenable.dispose();
    super.dispose();
  }
}

/// 目录大小异步计算状态。
class DirectorySizeState {
  const DirectorySizeState._({this.size, required this.isLoading});

  const DirectorySizeState.loading() : this._(isLoading: true);

  const DirectorySizeState.ready(int size)
      : this._(size: size, isLoading: false);

  const DirectorySizeState.failed() : this._(isLoading: false);

  final int? size;
  final bool isLoading;
}
