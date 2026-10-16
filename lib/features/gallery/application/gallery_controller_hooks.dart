part of 'gallery_controller.dart';

/// [GalleryIndexHooks] 的具体实现，拆分到 part 文件：
/// 上传前缩略图准备、上传/删除/还原后的索引增量更新与缓存联动。
///
/// 通过 mixin 挂到 [GalleryController] 上；mixin 声明其依赖的宿主成员，
/// 由宿主类的同库私有字段与方法提供实现。
mixin _GalleryControllerHooks implements GalleryIndexHooks {
  // ---- 宿主成员（由 GalleryController 提供）----

  MediaBridge get _mediaBridge;
  PhotoIndexRepository get _repository;
  OriginalCacheStore get _cacheStore;
  GalleryDatabase get _database;
  UserSession? get _session;
  bool get _scanInProgress;
  Set<String> get _scanPendingUpserts;
  Set<String> get _scanPendingDeletes;
  set _entries(List<PhotoEntry> value);
  Future<void> _refreshCachedKeys();
  void notifyListeners();

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
    final session = _session;
    if (session == null || !session.isRemote) return;
    final entry = await _repository.addUploadedMedia(
      session,
      objectPath: objectPath,
      localPath: localPath,
      thumbLocalPath: thumbLocalPath,
    );
    if (entry == null) return;
    if (_scanInProgress) _scanPendingUpserts.add(entry.key);
    _entries = await _database.readAllEntries();
    notifyListeners();
  }

  @override
  Future<void> onObjectsDeleted(Set<String> objectKeys) async {
    final session = _session;
    if (session == null || !session.isRemote) return;
    if (_scanInProgress) {
      _scanPendingDeletes
          .addAll(objectKeys.where(_repository.isMediaKey));
    }
    await _repository.removeDeletedMedia(session, objectKeys);
    await _cacheStore.removeCached(objectKeys);
    _entries = await _database.readAllEntries();
    await _refreshCachedKeys();
    notifyListeners();
  }

  @override
  Future<void> onObjectsRestored(Set<String> objectKeys) async {
    final session = _session;
    if (session == null || !session.isRemote) return;
    if (_scanInProgress) {
      _scanPendingUpserts
          .addAll(objectKeys.where(_repository.isMediaKey));
    }
    await _repository.restoreMedia(session, objectKeys);
    _entries = await _database.readAllEntries();
    notifyListeners();
  }
}
