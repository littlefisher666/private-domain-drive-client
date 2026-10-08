import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../shared/cache/disk_image_cache.dart';
import '../../../shared/state/app_controller.dart';
import '../../auth/domain/user_session.dart';
import '../../transfer/domain/transfer_task.dart';
import '../../workspace/domain/file_item.dart';
import '../../workspace/infrastructure/oss_client.dart';
import '../domain/gallery_config.dart';
import '../domain/photo_entry.dart';
import '../domain/photo_manifest.dart';
import '../domain/timeline_group.dart';
import '../infrastructure/gallery_database.dart';
import '../infrastructure/media_bridge.dart';
import '../infrastructure/original_cache_store.dart';
import '../infrastructure/photo_index_repository.dart';

enum GalleryPhase { idle, loading, scanning, repairing, ready, error }

/// 相册模块应用层控制器：索引同步、时间线数据、原图缓存状态与批量操作。
class GalleryController extends ChangeNotifier implements GalleryIndexHooks {
  GalleryController({
    required AppController appController,
    required OssClient ossClient,
    GalleryDatabase? database,
    MediaBridge? mediaBridge,
    ClipboardBridge? clipboardBridge,
  })  : _app = appController,
        _ossClient = ossClient,
        _database = database ?? GalleryDatabase(),
        _mediaBridge = mediaBridge ?? MediaBridge(),
        _clipboard = clipboardBridge ?? ClipboardBridge() {
    _repository = PhotoIndexRepository(
      ossClient: _ossClient,
      database: _database,
      mediaBridge: _mediaBridge,
    );
    _cacheStore = OriginalCacheStore(_database);
  }

  final AppController _app;
  final OssClient _ossClient;
  final GalleryDatabase _database;
  final MediaBridge _mediaBridge;
  final ClipboardBridge _clipboard;
  late final PhotoIndexRepository _repository;
  late final OriginalCacheStore _cacheStore;

  /// 复制成功的瞬时反馈：按钮与 ⌘C 共用，2 秒后自动复位。
  final ValueNotifier<bool> clipboardCopiedListenable =
      ValueNotifier<bool>(false);
  Timer? _copyFeedbackTimer;

  GalleryPhase _phase = GalleryPhase.idle;
  String? _errorMessage;
  String? _accountKey;
  List<PhotoEntry> _entries = const <PhotoEntry>[];
  String? _repairNotice;
  bool _thumbBackfillStarted = false;

  /// 已缓存原图的对象 key 集合（角标与秒开判断依据）。
  final ValueNotifier<Set<String>> cachedKeysListenable =
      ValueNotifier<Set<String>>(<String>{});

  /// 全量扫描进度（processed, total）；null 表示不在扫描中。
  final ValueNotifier<(int, int)?> scanProgressListenable =
      ValueNotifier<(int, int)?>(null);

  /// 当前选中的对象 key（多选/框选共用）。
  final ValueNotifier<Set<String>> selectionListenable =
      ValueNotifier<Set<String>>(<String>{});

  GalleryPhase get phase => _phase;
  String? get errorMessage => _errorMessage;
  List<PhotoEntry> get entries => _entries;
  bool get needsRepairNotice => _repairNotice != null;
  String? get repairNotice => _repairNotice;
  bool get isSelecting => selectionListenable.value.isNotEmpty;
  Set<String> get selectedKeys => selectionListenable.value;

  bool get isDesktop => !Platform.isAndroid && !Platform.isIOS;

  /// 传输任务只读快照（查看器判断原图下载状态用）。
  List<TransferTask> get appTasks => _app.tasks;

  bool isCached(String key) => cachedKeysListenable.value.contains(key);

  int get uncachedCount {
    final cached = cachedKeysListenable.value;
    return _entries.where((entry) => !cached.contains(entry.key)).length;
  }

  List<TimelineGroup> timelineGroups() => groupTimeline(_entries);

  /// 进入相册页时的索引装载入口。
  Future<void> load() async {
    if (_phase == GalleryPhase.scanning) return;
    final session = _app.session;
    if (session == null || !session.isRemote) {
      _phase = GalleryPhase.error;
      _errorMessage = '请先登录';
      notifyListeners();
      return;
    }
    try {
      await _app.ensureSessionReady();
    } catch (error) {
      debugPrint('[gallery] 会话校验失败: $error');
      _phase = GalleryPhase.error;
      _errorMessage = '会话不可用，请重新登录';
      notifyListeners();
      return;
    }
    final current = _app.session;
    if (current == null) {
      _phase = GalleryPhase.error;
      _errorMessage = '请先登录';
      notifyListeners();
      return;
    }
    final accountKey =
        '${current.ossConfig?.bucket ?? ''}|${current.userId}';
    if (_accountKey != accountKey || _phase == GalleryPhase.idle) {
      try {
        await _database.open(
          bucket: current.ossConfig?.bucket ?? '',
          userId: current.userId,
        );
      } catch (error) {
        debugPrint('[gallery] 打开元数据库失败: $error');
      }
      _accountKey = accountKey;
      _thumbBackfillStarted = false;
      await _refreshCachedKeys();
    }

    try {
      await _cacheStore.cleanExpired();
      await _cacheStore.validateIntegrity();
      await _refreshCachedKeys();
    } catch (error) {
      debugPrint('[gallery] 缓存清理失败: $error');
    }

    _entries = await _database.readAllEntries();
    final meta = await _database.readIndexMeta();
    if (meta == null) {
      // 其他设备可能已完成全量扫描：优先复用 OSS 清单，避免重复解析。
      if (await _tryAdoptRemoteManifest(current)) {
        _phase = GalleryPhase.ready;
        notifyListeners();
        unawaited(_backfillMissingThumbnails(current));
        return;
      }
      _phase = GalleryPhase.scanning;
      scanProgressListenable.value = (0, 0);
      notifyListeners();
      await _runFullScan(current);
      return;
    }
    if (meta.needsRepair) {
      _repairNotice = '照片索引需要修复，正在后台重建…';
      _phase = _entries.isEmpty
          ? GalleryPhase.scanning
          : GalleryPhase.repairing;
      if (_entries.isEmpty) scanProgressListenable.value = (0, 0);
      notifyListeners();
      unawaited(_runFullScan(current));
      return;
    }
    _phase = GalleryPhase.ready;
    notifyListeners();
    unawaited(_syncFromRemote(current, meta));
    unawaited(_backfillMissingThumbnails(current));
  }

  /// 手动重建索引：全量重扫 OSS 媒体对象并回写远端清单，用于补齐
  /// 旧版本上传未增量入索引的照片。
  Future<void> rebuildIndex() async {
    if (_phase == GalleryPhase.scanning) return;
    final session = _app.session;
    if (session == null || !session.isRemote) {
      _phase = GalleryPhase.error;
      _errorMessage = '请先登录';
      notifyListeners();
      return;
    }
    _repairNotice = null;
    _phase = GalleryPhase.scanning;
    scanProgressListenable.value = (0, 0);
    notifyListeners();
    await _runFullScan(session);
  }

  /// 新设备首次进相册时采纳远端清单：本地不再重复全量扫描。
  /// 清单缺失或标记待修复时返回 false，走全量扫描。
  Future<bool> _tryAdoptRemoteManifest(UserSession session) async {
    try {
      final loaded = await _repository.loadManifest(session);
      if (loaded == null) return false;
      final (manifest, _) = loaded;
      if (manifest.needsRepair) return false;
      // 旧格式清单的拍摄时间可能有缺陷（fv < 当前版本），重扫以生成
      // 新格式，避免旧数据被永久采纳。
      if (manifest.formatVersion < PhotoManifest.currentFormatVersion) {
        return false;
      }
      await _database.replaceEntries(manifest.entries);
      await _database.writeIndexMeta(PhotoIndexMeta(
        version: manifest.version,
        scannedAt: manifest.scannedAt,
        needsRepair: false,
      ));
      _entries = manifest.entries;
      return true;
    } catch (error) {
      debugPrint('[gallery] 复用远端清单失败: $error');
      return false;
    }
  }

  Future<void> _runFullScan(UserSession session) async {
    try {
      final manifest = await _repository.fullScan(
        session,
        onProgress: (processed, total) {
          scanProgressListenable.value = (processed, total);
        },
      );
      _entries = manifest.entries;
      _repairNotice = manifest.needsRepair ? '索引清单暂未同步，稍后将自动重试' : null;
      _phase = GalleryPhase.ready;
    } catch (error) {
      debugPrint('[gallery] 全量扫描失败: $error');
      _phase = GalleryPhase.error;
      _errorMessage = '建立照片索引失败，请稍后重试';
    } finally {
      scanProgressListenable.value = null;
      await _refreshCachedKeys();
      notifyListeners();
      if (_phase == GalleryPhase.ready) {
        unawaited(_backfillMissingThumbnails(session));
      }
    }
  }

  /// 存量缩略图补齐（视频截帧/超大图本地缩放）：每次会话最多执行
  /// 一次，失败条目留待下次进入相册页自动重试。
  Future<void> _backfillMissingThumbnails(UserSession session) async {
    if (_thumbBackfillStarted) return;
    _thumbBackfillStarted = true;
    try {
      final count = await _repository.backfillMissingThumbnails(
        session,
        // 单张补齐完成即更新内存列表并刷新，网格无需等整批结束。
        onEntryUpdated: (entry) {
          _entries = <PhotoEntry>[
            for (final item in _entries)
              if (item.key == entry.key) entry else item,
          ];
          notifyListeners();
        },
      );
      if (count > 0) {
        _entries = await _database.readAllEntries();
        await _refreshCachedKeys();
        notifyListeners();
        debugPrint('[gallery] 缩略图补齐完成: $count');
      }
    } catch (error) {
      debugPrint('[gallery] 缩略图补齐失败: $error');
    }
  }

  /// 后台拉取远端清单：版本更新则替换本地副本，损坏则触发重建。
  Future<void> _syncFromRemote(UserSession session, PhotoIndexMeta meta) async {
    try {
      final loaded = await _repository.loadManifest(session);
      if (loaded == null) {
        await _database.writeIndexMeta(PhotoIndexMeta(
          version: meta.version,
          scannedAt: meta.scannedAt,
          needsRepair: true,
        ));
        _repairNotice = '照片索引需要修复，正在后台重建…';
        notifyListeners();
        await _runFullScan(session);
        return;
      }
      final (manifest, _) = loaded;
      // 旧格式清单的拍摄时间可能有缺陷（fv < 当前版本），触发重扫
      // 生成新格式，避免旧数据被同步回本地。
      if (manifest.formatVersion < PhotoManifest.currentFormatVersion) {
        await _database.writeIndexMeta(PhotoIndexMeta(
          version: meta.version,
          scannedAt: meta.scannedAt,
          needsRepair: true,
        ));
        _repairNotice = '照片索引需要修复，正在后台重建…';
        notifyListeners();
        await _runFullScan(session);
        return;
      }
      if (manifest.version > meta.version) {
        await _database.replaceEntries(manifest.entries);
        await _database.writeIndexMeta(PhotoIndexMeta(
          version: manifest.version,
          scannedAt: manifest.scannedAt,
          needsRepair: false,
        ));
        _entries = await _database.readAllEntries();
        notifyListeners();
      }
    } on FormatException {
      await _database.writeIndexMeta(PhotoIndexMeta(
        version: meta.version,
        scannedAt: meta.scannedAt,
        needsRepair: true,
      ));
      _repairNotice = '照片索引需要修复，正在后台重建…';
      notifyListeners();
      await _runFullScan(session);
    } catch (error) {
      debugPrint('[gallery] 远端清单同步失败: $error');
    }
  }

  Future<void> _refreshCachedKeys() async {
    try {
      final paths = await _database.readAllCachedPaths();
      cachedKeysListenable.value = Set<String>.unmodifiable(paths.keys);
    } catch (_) {
      // 读取失败时保持现状，角标以最后一次成功状态为准。
    }
  }

  // ---------- 缩略图加载 ----------

  String get _cacheNamespace => _app.thumbnailCacheNamespace;

  String _gridCacheKey(PhotoEntry entry) => DiskImageCache.cacheKey(
        namespace: _cacheNamespace,
        path: entry.key,
        versionToken: '${entry.modifiedMs ?? 0}|${entry.size}',
        process: 'gallery-grid',
      );

  /// 相册网格缩略图：有索引缩略图映射（视频截帧/超大图本地生成）优先
  /// 走缩略图对象，其余图片走 OSS 图片处理参数；无映射返回 null，
  /// 由界面展示占位图。
  Future<List<int>?> loadGridThumbnail(PhotoEntry entry) async {
    final cached = await DiskImageCache.instance.read(
      DiskImageCacheKind.thumbnails,
      _gridCacheKey(entry),
    );
    if (cached != null) return cached;
    final session = _app.session;
    if (session == null) return null;
    try {
      final List<int> bytes;
      if (entry.thumbKey != null) {
        bytes = await _ossClient.download(entry.thumbKey!, session);
      } else if (entry.mediaType == PhotoMediaType.image) {
        bytes = await _ossClient.downloadThumbnail(
          entry.key,
          session,
          width: GalleryConfig.listThumbnailSize,
          height: GalleryConfig.listThumbnailSize,
        );
      } else {
        return null;
      }
      unawaited(DiskImageCache.instance.write(
        DiskImageCacheKind.thumbnails,
        _gridCacheKey(entry),
        bytes,
      ));
      return bytes;
    } catch (error) {
      debugPrint('[gallery] 缩略图加载失败 ${entry.key}: $error');
      return null;
    }
  }

  /// 加载视频截帧缩略图对象（查看器视频条目展示用）。
  Future<List<int>?> loadThumbObject(String? thumbKey) async {
    if (thumbKey == null) return null;
    final cacheKey = DiskImageCache.cacheKey(
      namespace: _cacheNamespace,
      path: thumbKey,
      versionToken: 'thumb',
      process: 'raw',
    );
    final cached = await DiskImageCache.instance.read(
      DiskImageCacheKind.thumbnails,
      cacheKey,
    );
    if (cached != null) return cached;
    final session = _app.session;
    if (session == null) return null;
    try {
      final bytes = await _ossClient.download(thumbKey, session);
      unawaited(DiskImageCache.instance.write(
        DiskImageCacheKind.thumbnails,
        cacheKey,
        bytes,
      ));
      return bytes;
    } catch (error) {
      debugPrint('[gallery] 视频缩略图加载失败 $thumbKey: $error');
      return null;
    }
  }

  /// 大图查看器降级缩略图（1200px）。
  Future<List<int>?> loadDegradedPreview(PhotoEntry entry) async {
    final cacheKey = DiskImageCache.cacheKey(
      namespace: _cacheNamespace,
      path: entry.key,
      versionToken: '${entry.modifiedMs ?? 0}|${entry.size}',
      process: 'image/resize,m_lfit,w_${GalleryConfig.degradedPreviewSize}',
    );
    final cached = await DiskImageCache.instance.read(
      DiskImageCacheKind.previews,
      cacheKey,
    );
    if (cached != null) return cached;
    final session = _app.session;
    if (session == null) return null;
    // 超大图 OSS 图片处理不支持（ImageTooLarge），直接用本地生成的
    // 缩略图对象放大展示。
    if (entry.size > GalleryConfig.oversizedImageLimit) {
      return loadThumbObject(entry.thumbKey);
    }
    try {
      final bytes = await _ossClient.downloadImagePreview(
        entry.key,
        session,
        width: GalleryConfig.degradedPreviewSize,
        height: GalleryConfig.degradedPreviewSize,
      );
      unawaited(DiskImageCache.instance.write(
        DiskImageCacheKind.previews,
        cacheKey,
        bytes,
      ));
      return bytes;
    } catch (error) {
      debugPrint('[gallery] 降级预览加载失败 ${entry.key}: $error');
      return null;
    }
  }

  /// 已缓存原图的本地文件（秒开入口）；未缓存返回 null。
  Future<File?> resolveOriginalFile(PhotoEntry entry) =>
      _cacheStore.readOriginal(entry.key);

  // ---------- 选择 ----------

  void selectOnly(PhotoEntry entry) {
    selectionListenable.value = {entry.key};
  }

  void toggleSelection(PhotoEntry entry) {
    final next = <String>{...selectionListenable.value};
    if (!next.remove(entry.key)) {
      next.add(entry.key);
    }
    selectionListenable.value = Set<String>.unmodifiable(next);
  }

  void addToSelection(PhotoEntry entry, {bool subtract = false}) {
    final next = <String>{...selectionListenable.value};
    if (subtract) {
      next.remove(entry.key);
    } else {
      next.add(entry.key);
    }
    selectionListenable.value = Set<String>.unmodifiable(next);
  }

  void replaceSelection(Iterable<String> keys) {
    selectionListenable.value = Set<String>.unmodifiable(keys.toSet());
  }

  void selectAll() {
    selectionListenable.value =
        Set<String>.unmodifiable(_entries.map((entry) => entry.key));
  }

  void clearSelection() {
    selectionListenable.value = const <String>{};
  }

  PhotoEntry? entryOfKey(String key) {
    for (final entry in _entries) {
      if (entry.key == key) return entry;
    }
    return null;
  }

  // ---------- 原图下载 ----------

  /// 通过传输队列后台下载原图到相册缓存；完成后角标即时消失。
  /// 返回传输任务 id。
  Future<String> downloadOriginal(PhotoEntry entry) async {
    await _cleanOverCapacityQuietly();
    final target = await _cacheStore.fileFor(entry.key);
    return _app.enqueueOriginalDownload(
      path: entry.key,
      name: entry.name,
      totalBytes: entry.size,
      target: target,
      onCompleted: (file) async {
        await _cacheStore.recordCached(
          objectKey: entry.key,
          file: file,
          size: entry.size,
        );
        await _refreshCachedKeys();
        notifyListeners();
      },
    );
  }

  // ---------- 视频在线播放 ----------

  /// 为视频条目生成 OSS GetObject 预签名 URL（流式播放用）。
  /// URL 仅内存返回，不缓存、不落盘；失败返回 null，由界面提示重试。
  Future<String?> presignVideoUrl(PhotoEntry entry) async {
    final session = _app.session;
    if (session == null || !session.isRemote) return null;
    try {
      return await _ossClient.presignGetObjectUrl(entry.key, session);
    } catch (error) {
      debugPrint('[gallery] 生成视频播放地址失败 ${entry.key}: $error');
      return null;
    }
  }

  // ---------- 批量操作 ----------

  /// 批量删除（回收站流程）。索引与缓存清理由删除钩子完成。
  Future<BatchDeleteSummary?> deleteEntries(Iterable<PhotoEntry> selected) async {
    final items = selected
        .map((entry) => FileItem(
              path: entry.key,
              name: entry.name,
              isDirectory: false,
              size: entry.size,
            ))
        .toList();
    try {
      final preview = await _app.prepareBatchDelete(items);
      final summary = await _app.deleteBatch(preview);
      return summary;
    } finally {
      clearSelection();
    }
  }

  /// 批量下载原图到相册缓存（多选操作栏）。
  void downloadOriginals(Iterable<PhotoEntry> selected) {
    for (final entry in selected) {
      if (!isCached(entry.key)) {
        unawaited(downloadOriginal(entry));
      }
    }
  }

  /// 下载前容量预检：超限时 LRU 清理至阈值以下；失败不阻塞下载。
  Future<void> _cleanOverCapacityQuietly() async {
    try {
      await _cacheStore.cleanOverCapacity();
    } catch (error) {
      debugPrint('[gallery] 缓存容量清理失败: $error');
    }
  }

  /// macOS 复制所选原图到系统剪贴板；未缓存条目先下载后复制。
  /// 返回错误信息（null 表示成功）。
  Future<String?> copyToClipboard(Iterable<PhotoEntry> selected) async {
    final files = <File>[];
    for (final entry in selected) {
      try {
        final local = await ensureOriginalLocal(entry,
            progressLabel: '正在准备复制');
        files.add(local);
      } catch (error) {
        return '下载原图失败：${entry.name}';
      }
    }
    final ok = await _clipboard.copyImageFiles(files.map((file) => file.path));
    if (ok) _markClipboardCopied();
    return ok ? null : '写入剪贴板失败';
  }

  void _markClipboardCopied() {
    _copyFeedbackTimer?.cancel();
    clipboardCopiedListenable.value = true;
    _copyFeedbackTimer = Timer(const Duration(seconds: 2), () {
      clipboardCopiedListenable.value = false;
    });
  }

  /// macOS 相册页粘贴上传：读取剪贴板图片写临时文件走现有上传管线。
  /// 非图片内容静默忽略。
  Future<void> pasteUpload() async {
    final image = await _clipboard.readImage();
    if (image == null) return;
    try {
      final temp = await getTemporaryDirectory();
      final directory = Directory('${temp.path}${Platform.pathSeparator}gallery_paste');
      await directory.create(recursive: true);
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        '${DateTime.now().microsecondsSinceEpoch}.${image.extension}',
      );
      await file.writeAsBytes(image.bytes, flush: true);
      await _app.uploadFile(
        fileName: file.uri.pathSegments.last,
        localPath: file.path,
        fileSize: image.bytes.length,
      );
    } catch (error) {
      // 粘贴上传失败保持静默，不提供 UI 提示入口。
      debugPrint('[gallery] 粘贴上传失败: $error');
    }
  }

  /// Android 系统分享：未缓存先下载原图（失败中止），多张走多图分享。
  Future<String?> shareEntries(Iterable<PhotoEntry> selected) async {
    final files = <XFile>[];
    for (final entry in selected) {
      try {
        final local = await ensureOriginalLocal(entry, progressLabel: '正在准备分享');
        files.add(XFile(local.path));
      } catch (error) {
        return '下载原图失败：${entry.name}';
      }
    }
    if (files.isEmpty) return null;
    await SharePlus.instance.share(ShareParams(files: files));
    return null;
  }

  /// 确保原图在本机：已缓存直接返回；未缓存先下载到缓存目录并写记录。
  Future<File> ensureOriginalLocal(
    PhotoEntry entry, {
    String progressLabel = '正在下载',
  }) async {
    final existing = await _cacheStore.readOriginal(entry.key);
    if (existing != null) return existing;
    await _cleanOverCapacityQuietly();
    final session = _app.session;
    if (session == null || !session.isRemote) {
      throw StateError('请先登录');
    }
    final file = await _cacheStore.fileFor(entry.key);
    final temporary = File('${file.path}.share.part');
    try {
      await _ossClient.downloadToFile(
        entry.key,
        session,
        temporary,
        taskId: 'gallery-ensure-${DateTime.now().microsecondsSinceEpoch}',
        onProgress: (_, __) {},
        isCanceled: () => false,
      );
      await temporary.rename(file.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
    await _cacheStore.recordCached(
      objectKey: entry.key,
      file: file,
      size: entry.size,
    );
    await _refreshCachedKeys();
    notifyListeners();
    return file;
  }

  // ---------- GalleryIndexHooks ----------

  @override
  Future<String?> prepareVideoThumbnail(
      String objectPath, String localPath) async {
    final bytes = await _mediaBridge.captureVideoThumbnail(localPath);
    if (bytes == null) return null;
    final temp = await getTemporaryDirectory();
    final directory =
        Directory('${temp.path}${Platform.pathSeparator}gallery_thumbs');
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      '${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  @override
  Future<String?> prepareImageThumbnail(
      String objectPath, String localPath) async {
    try {
      final file = File(localPath);
      if (await file.length() <= GalleryConfig.oversizedImageLimit) {
        return null;
      }
      final bytes = await _mediaBridge.resizeImage(localPath);
      if (bytes == null) return null;
      final temp = await getTemporaryDirectory();
      final directory =
          Directory('${temp.path}${Platform.pathSeparator}gallery_thumbs');
      await directory.create(recursive: true);
      final thumb = File(
        '${directory.path}${Platform.pathSeparator}'
        '${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await thumb.writeAsBytes(bytes, flush: true);
      return thumb.path;
    } catch (error) {
      debugPrint('[gallery] 超大图缩略图生成失败（不阻塞）: $error');
      return null;
    }
  }

  @override
  Future<void> onMediaUploaded({
    required String objectPath,
    required String localPath,
    String? thumbLocalPath,
  }) async {
    final session = _app.session;
    if (session == null || !session.isRemote) return;
    final entry = await _repository.addUploadedMedia(
      session,
      objectPath: objectPath,
      localPath: localPath,
      thumbLocalPath: thumbLocalPath,
    );
    if (entry == null) return;
    _entries = await _database.readAllEntries();
    notifyListeners();
  }

  @override
  Future<void> onObjectsDeleted(Set<String> objectKeys) async {
    final session = _app.session;
    if (session == null || !session.isRemote) return;
    await _repository.removeDeletedMedia(session, objectKeys);
    await _cacheStore.removeCached(objectKeys);
    _entries = await _database.readAllEntries();
    await _refreshCachedKeys();
    notifyListeners();
  }

  @override
  Future<void> onObjectsRestored(Set<String> objectKeys) async {
    final session = _app.session;
    if (session == null || !session.isRemote) return;
    await _repository.restoreMedia(session, objectKeys);
    _entries = await _database.readAllEntries();
    notifyListeners();
  }

  @override
  void dispose() {
    _copyFeedbackTimer?.cancel();
    cachedKeysListenable.dispose();
    scanProgressListenable.dispose();
    selectionListenable.dispose();
    clipboardCopiedListenable.dispose();
    unawaited(_database.close());
    super.dispose();
  }
}
