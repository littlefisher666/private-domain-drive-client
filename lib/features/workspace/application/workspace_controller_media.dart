part of 'workspace_controller.dart';

/// WorkspaceController 的媒体加载实现：缩略图、在线预览图、PDF
/// 文档、文本预览加载器与流式播放预签名 URL。
mixin _WorkspaceControllerMedia on _WorkspaceControllerCore {
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
}
