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

/// 工作区域控制器：目录浏览与导航、条目选择、创建/重命名、
/// 排序与缩略图偏好、目录统计摘要与媒体加载。
class WorkspaceController extends ChangeNotifier {
  WorkspaceController({
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

  // ---------- 浏览 / 列表 ----------

  Future<List<FileItem>> listDirectory([String? path]) async {
    final session = _sessionController.session;
    if (session == null || !session.isRemote || session.credentials == null) {
      throw AppError('请先登录', code: 'REMOTE_SESSION_REQUIRED');
    }
    await _sessionController.ensureSessionReady();
    final target = path ?? _currentPath;
    final results = await Future.wait<dynamic>([
      _ossClient.list(target, session),
      _loadAliasTable(session),
    ]);
    final items = results[0] as List<FileItem>;
    final merged = await _mergeAliasItems(items, session, target);
    if (target == _currentPath) {
      final beforeCount = _remoteDirectories.length;
      _remoteDirectories
        ..add(_currentPath)
        ..addAll(
            merged.where((item) => item.isDirectory).map((item) => item.path));
      if (_remoteDirectories.length != beforeCount) {
        notifyListeners();
      }
    }
    return _sortDirectoryItems(
      merged,
      session,
      _fileSortOptionForPath(target),
    );
  }

  /// 刷新别名表；读取失败保留旧表，不阻塞目录浏览。
  Future<void> _loadAliasTable(UserSession session) async {
    try {
      _aliasTable = await _aliasRepository.load(session);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[alias] 别名表加载失败，沿用旧表: $error');
      }
    }
  }

  /// 将挂载于 [path] 层级的别名条目合并进目录列表：渲染为带链接标识的
  /// 文件夹，统计信息取目标前缀的直属内容，计入所在层级条目统计。
  Future<List<FileItem>> _mergeAliasItems(
    List<FileItem> items,
    UserSession session,
    String path,
  ) async {
    if (_aliasTable.isEmpty) return items;
    final level = normalizeDirPath(path);
    final mounted = _aliasTable.aliases
        .where((alias) => normalizeDirPath(alias.parentPrefix) == level)
        .toList(growable: false);
    if (mounted.isEmpty) return items;
    // 同层级别名允许指向同层真实目录（如目录改名快捷入口），此时真实
    // 条目与别名条目并列展示；批量操作按 isAlias 区分二者。
    final summaries = await Future.wait<DirectorySummary?>(
      mounted.map((alias) async {
        try {
          return await _ossClient.directorySummary(alias.targetPrefix, session);
        } catch (_) {
          return null;
        }
      }),
    );
    return <FileItem>[
      ...items,
      for (var index = 0; index < mounted.length; index++)
        FileItem(
          path: mounted[index].targetPrefix,
          name: mounted[index].name,
          isDirectory: true,
          itemCount: summaries[index]?.itemCount,
          updatedAt: summaries[index]?.updatedAt,
          isAlias: true,
          aliasId: mounted[index].id,
          createdBy: mounted[index].createdBy,
        ),
    ];
  }

  /// 目录选择器专用：仅前缀列举子目录（单次请求），不做子内容统计。
  Future<List<FileItem>> listSubdirectories(String path) async {
    final session = _sessionController.session;
    if (session == null || !session.isRemote || session.credentials == null) {
      throw AppError('请先登录', code: 'REMOTE_SESSION_REQUIRED');
    }
    await _sessionController.ensureSessionReady();
    final prefix = normalizeDirPath(path);
    final prefixes = await _ossClient.listPrefixes(prefix, session);
    return <FileItem>[
      for (final dirPrefix in prefixes)
        if (!dirPrefix.substring(prefix.length).startsWith('.'))
          FileItem(
            path: dirPrefix,
            name: dirPrefix.substring(prefix.length, dirPrefix.length - 1),
            isDirectory: true,
          ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// 目录选择器使用：与 [listSubdirectories] 一致，但按层级合并挂载于
  /// [path] 的别名条目（path 指向目标目录），使别名可作为移动/挂载目标。
  Future<List<FileItem>> listPickerDirectories(String path) async {
    final directories = await listSubdirectories(path);
    if (_aliasTable.aliases.isEmpty) {
      return directories;
    }
    final level = normalizeDirPath(path);
    final realPaths = directories.map((item) => item.path).toSet();
    final aliasItems = <FileItem>[
      for (final alias in _aliasTable.aliases)
        if (normalizeDirPath(alias.parentPrefix) == level &&
            realPaths.add(alias.targetPrefix))
          FileItem(
            path: alias.targetPrefix,
            name: alias.name,
            isDirectory: true,
            isAlias: true,
            createdBy: alias.createdBy,
          ),
    ];
    if (aliasItems.isEmpty) return directories;
    return [...directories, ...aliasItems]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  // ---------- 目录统计摘要 ----------

  /// 读取单个目录统计的缓存命中值；未命中返回 null。
  Future<DirectorySummary?> cachedDirectorySummary(String path) =>
      _directorySummaryService.cached(path);

  /// 批量读取目录统计缓存命中值，key 为目录路径。
  Future<Map<String, DirectorySummary>> cachedDirectorySummaries(
          Iterable<String> paths) =>
      _directorySummaryService.cachedAll(paths);

  /// 后台受限并发统计子文件夹并逐个回调，不阻塞调用方。
  Future<void> refreshDirectorySummaries(
    Iterable<String> paths, {
    required void Function(String path, DirectorySummary summary) onResult,
  }) =>
      _directorySummaryService.refresh(paths, onResult);

  void noteDirectoryFilesAdded(String dir, int count, DateTime at) =>
      _directorySummaryService.noteFilesAdded(dir, count, at);

  void noteDirectoryFilesRemoved(String dir, int count) =>
      _directorySummaryService.noteFilesRemoved(dir, count);

  void invalidateDirectorySummary(String dir) =>
      _directorySummaryService.invalidate(dir);

  /// 回收站清理等不可靠路径调用 invalidate。写修正后同时触发该目录的
  /// 后台校准，让计数最终与 OSS 一致；校准不阻塞操作反馈。
  void calibrateDirectorySummary(String dir) {
    unawaited(_directorySummaryService.refresh(<String>[dir], (_, __) {}));
  }

  /// 对一组成功删除/新增的顶层条目按所属目录修正统计缓存。
  void noteTopLevelChanges(
    Iterable<String> topLevelPaths,
    Set<String> failedPaths, {
    required int delta,
  }) {
    final affected = <String>{};
    final counts = <String, int>{};
    for (final path in topLevelPaths) {
      final parent = normalizeDirPath(parentPathOf(path));
      affected.add(parent);
      if (failedPaths.contains(path)) {
        // 该条目未能删除/搬运，无法可靠增量，直接失效由校准重建。
        _directorySummaryService.invalidate(parent);
        continue;
      }
      counts[parent] = (counts[parent] ?? 0) + delta.abs();
    }
    counts.forEach((dir, count) {
      if (delta >= 0) {
        _directorySummaryService.noteFilesAdded(dir, count, DateTime.now());
      } else {
        _directorySummaryService.noteFilesRemoved(dir, count);
      }
    });
    for (final dir in affected) {
      calibrateDirectorySummary(dir);
    }
  }

  // ---------- 媒体加载 ----------

  Future<List<int>> loadThumbnail(FileItem item) async {
    if (item.isDirectory || item.kind != FileKind.image) {
      throw StateError('只有图片文件支持缩略图');
    }
    final session = _sessionController.requireSession();
    await _sessionController.ensureSessionReady();
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
    final bytes = await _ossClient.downloadThumbnail(
        item.path, _sessionController.session ?? session);
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
    final session = _sessionController.requireSession();
    await _sessionController.ensureSessionReady();
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
    final bytes = await _ossClient.downloadImagePreview(
        item.path, _sessionController.session ?? session);
    unawaited(DiskImageCache.instance.write(
      DiskImageCacheKind.previews,
      cacheKey,
      bytes,
    ));
    return bytes;
  }

  /// 加载 PDF 文档本地文件：缓存命中直接返回；未命中走预签名 URL
  /// 流式下载落盘后写入文档缓存。失败时抛出异常由界面展示重试。
  Future<File> loadPdfDocument(FileItem item) async {
    if (item.isDirectory || item.kind != FileKind.pdf) {
      throw StateError('只有 PDF 文件支持文档预览');
    }
    final session = _sessionController.requireSession();
    await _sessionController.ensureSessionReady();
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
    final session = _sessionController.requireSession();
    return TextPreviewLoader(
      ossClient: _ossClient,
      session: session,
      path: item.path,
      fileSize: item.size,
    );
  }

  /// 生成音频等对象的预签名 URL，用于 media_kit 流式播放。
  Future<String> presignMediaUrl(FileItem item) async {
    final session = _sessionController.requireSession();
    await _sessionController.ensureSessionReady();
    return _ossClient.presignObjectUrl(
        item.path, _sessionController.session ?? session);
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

  // ---------- 选择 ----------

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

  void clearSelectedItem() {
    selectedItemListenable.value = null;
  }

  Future<void> _loadDirectorySize(FileItem item) async {
    final path = normalizeDirPath(item.path);
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
      await _sessionController.ensureSessionReady();
      final size = await _ossClient.calculateDirectorySize(
        path,
        _sessionController.requireSession(),
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

  void clearDirectorySizeCache() {
    _directorySizeCache.clear();
    _directorySizeRequests.clear();
    directorySizeStatesListenable.value = const <String, DirectorySizeState>{};
  }

  Future<void> _loadSelectedImageTakenAt(FileItem item) async {
    final session = _sessionController.session;
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
    // 链接条目与真实条目可能共用同一路径（同层指向），批量操作按 isAlias
    // 区分二者；多选基于路径无法区分，故链接条目不参与多选。
    if (item.isAlias) {
      return;
    }
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
