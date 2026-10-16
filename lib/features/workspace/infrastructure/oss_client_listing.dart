part of 'oss_client.dart';

/// OssClient 的目录列举与统计实现：单层列举、递归 key/对象遍历、
/// 目录统计、目录创建与前缀/存在性查询。
mixin _OssClientListing on _OssClientCore {
  Future<List<FileItem>> list(String path, UserSession session) async {
    await _ensureConfigured(session);
    final prefix = _dir(path);
    final directories = <FileItem>[];
    final files = <FileItem>[];
    String? marker;
    do {
      final page = await _platform(
        () => _native.listObjects(
          prefix: prefix,
          delimiter: '/',
          marker: marker,
          maxKeys: 1000,
        ),
      );
      directories.addAll(<FileItem>[
        for (final key in page.commonPrefixes)
          if (key != prefix && !_isHiddenEntry(key, prefix))
            FileItem(
              path: key,
              name:
                  key.substring(prefix.length).replaceFirst(RegExp(r'/$'), ''),
              isDirectory: true,
            ),
      ]);
      files.addAll(<FileItem>[
        for (final object in page.objects)
          if (object.key != prefix &&
              !object.key.substring(prefix.length).contains('/') &&
              !_isHiddenEntry(object.key, prefix))
            FileItem(
              path: object.key,
              name: object.key.substring(prefix.length),
              isDirectory: false,
              size: object.size,
              updatedAt: object.lastModifiedMilliseconds == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(
                      object.lastModifiedMilliseconds!,
                      isUtc: true,
                    ).toLocal(),
            ),
      ]);
      marker = page.isTruncated ? page.nextMarker : null;
      if (page.isTruncated && (marker == null || marker.isEmpty)) {
        throw AppError('OSS 分页响应缺少下一页标识', code: 'OSS_INVALID_RESPONSE');
      }
    } while (marker != null && marker.isNotEmpty);
    return [...directories, ...files];
  }

  /// 统计指定文件夹的直属条目数与最新更新时间，不递归遍历子目录。
  /// 每次调用完整翻页遍历该文件夹，调用方需自行控制并发与频率。
  Future<DirectorySummary> directorySummary(
    String path,
    UserSession session,
  ) async {
    await _ensureConfigured(session);
    return _readDirectorySummary(path);
  }

  Future<DirectorySummary> _readDirectorySummary(String path) async {
    final prefix = _dir(path);
    var itemCount = 0;
    DateTime? updatedAt;
    String? marker;
    do {
      final page = await _platform(
        () => _native.listObjects(
          prefix: prefix,
          delimiter: '/',
          marker: marker,
          maxKeys: 1000,
        ),
      );
      itemCount += page.commonPrefixes
          .where((key) => key != prefix && !_isHiddenEntry(key, prefix))
          .length;
      for (final object in page.objects) {
        if (object.key == prefix) {
          updatedAt = _latestUpdatedAt(updatedAt, object);
        } else if (!object.key.substring(prefix.length).contains('/') &&
            !_isHiddenEntry(object.key, prefix)) {
          itemCount++;
          updatedAt = _latestUpdatedAt(updatedAt, object);
        }
      }
      marker = page.isTruncated ? page.nextMarker : null;
      if (page.isTruncated && (marker == null || marker.isEmpty)) {
        throw AppError('OSS 分页响应缺少下一页标识', code: 'OSS_INVALID_RESPONSE');
      }
    } while (marker != null && marker.isNotEmpty);
    return DirectorySummary(itemCount: itemCount, updatedAt: updatedAt);
  }

  DateTime? _latestUpdatedAt(DateTime? current, OssNativeObject object) {
    final modified = object.lastModifiedMilliseconds;
    if (modified == null) return current;
    final candidate =
        DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true).toLocal();
    return current == null || candidate.isAfter(current) ? candidate : current;
  }

  /// 目录前缀是否真实存在：前缀下存在任意对象（含目录标记）或子前缀。
  Future<bool> directoryExists(String path, UserSession session) async {
    await _ensureConfigured(session);
    final page = await _platform(
      () => _native.listObjects(prefix: _dir(path), delimiter: '/', maxKeys: 1),
    );
    return page.objects.isNotEmpty || page.commonPrefixes.isNotEmpty;
  }

  /// 单层列举前缀下的直接子目录名与文件名（不含统计与隐藏过滤），
  /// 供别名名称冲突校验使用。
  Future<Set<String>> listEntryNames(
    String prefix,
    UserSession session,
  ) async {
    await _ensureConfigured(session);
    final names = <String>{};
    final dir = _dir(prefix);
    String? marker;
    do {
      final page = await _platform(() => _native.listObjects(
            prefix: dir,
            delimiter: '/',
            marker: marker,
            maxKeys: 1000,
          ));
      for (final key in page.commonPrefixes) {
        if (key != dir) {
          names.add(key.substring(dir.length).replaceFirst(RegExp(r'/$'), ''));
        }
      }
      for (final object in page.objects) {
        final relative = object.key.substring(dir.length);
        if (relative.isNotEmpty && !relative.contains('/')) {
          names.add(relative);
        }
      }
      marker = page.isTruncated ? page.nextMarker : null;
      if (page.isTruncated && (marker == null || marker.isEmpty)) {
        throw AppError('OSS 分页响应缺少下一页标识', code: 'OSS_INVALID_RESPONSE');
      }
    } while (marker != null && marker.isNotEmpty);
    return names;
  }

  Future<void> createFolder(String path, UserSession session) async {
    await _ensureConfigured(session);
    await _platform(() => _native.putEmptyObject(_dir(path)));
  }

  Future<List<String>> listAllObjectKeys(
    String path,
    UserSession session,
  ) async {
    await _ensureConfigured(session);
    final keys = <String>[];
    String? marker;
    do {
      final page = await _platform(
        () => _native.listObjects(
          prefix: _dir(path),
          marker: marker,
          maxKeys: 1000,
        ),
      );
      keys.addAll(page.objects.map((object) => object.key));
      marker = page.isTruncated ? page.nextMarker : null;
      if (page.isTruncated && (marker == null || marker.isEmpty)) {
        throw AppError('OSS 分页响应缺少下一页标识', code: 'OSS_INVALID_RESPONSE');
      }
    } while (marker != null && marker.isNotEmpty);
    return keys;
  }

  /// 递归列举前缀下全部对象 key，每返回一页（≤1000）即回调一次，供
  /// 移动等场景边列举边搬运；回调内对已列举 key 的删除可与翻页安全并发
  /// （OSS 按 key 字典序分页，已删除的源 key 均 ≤ 翻页 marker）。
  Future<void> forEachObjectKeyPage(
    String path,
    UserSession session,
    Future<void> Function(List<String> keys) onPage,
  ) async {
    await _ensureConfigured(session);
    String? marker;
    do {
      final page = await _platform(
        () => _native.listObjects(
          prefix: _dir(path),
          marker: marker,
          maxKeys: 1000,
        ),
      );
      final keys =
          page.objects.map((object) => object.key).toList(growable: false);
      if (keys.isNotEmpty) {
        await onPage(keys);
      }
      marker = page.isTruncated ? page.nextMarker : null;
      if (page.isTruncated && (marker == null || marker.isEmpty)) {
        throw AppError('OSS 分页响应缺少下一页标识', code: 'OSS_INVALID_RESPONSE');
      }
    } while (marker != null && marker.isNotEmpty);
  }

  /// 统计指定目录前缀下所有文件的总大小。
  ///
  /// OSS 的目录没有独立大小；每个列表分页已携带对象大小，因此无需逐个
  /// 请求对象元数据。目录标记对象不计入结果。
  Future<int> calculateDirectorySize(
    String path,
    UserSession session,
  ) async {
    await _ensureConfigured(session);
    final prefix = _dir(path);
    var totalSize = 0;
    String? marker;
    do {
      final page = await _platform(
        () => _native.listObjects(
          prefix: prefix,
          marker: marker,
          maxKeys: 1000,
        ),
      );
      for (final object in page.objects) {
        if (object.key != prefix && !object.key.endsWith('/')) {
          totalSize += object.size;
        }
      }
      marker = page.isTruncated ? page.nextMarker : null;
      if (page.isTruncated && (marker == null || marker.isEmpty)) {
        throw AppError('OSS 分页响应缺少下一页标识', code: 'OSS_INVALID_RESPONSE');
      }
    } while (marker != null && marker.isNotEmpty);
    return totalSize;
  }

  Future<List<String>> listPrefixes(
    String prefix,
    UserSession session,
  ) async {
    await _ensureConfigured(session);
    final prefixes = <String>[];
    String? marker;
    do {
      final page = await _platform(() => _native.listObjects(
            prefix: prefix,
            delimiter: '/',
            marker: marker,
            maxKeys: 1000,
          ));
      prefixes.addAll(page.commonPrefixes);
      marker = page.isTruncated ? page.nextMarker : null;
    } while (marker != null && marker.isNotEmpty);
    return prefixes;
  }

  Future<bool> objectExists(String path, UserSession session) async {
    await _ensureConfigured(session);
    final page = await _platform(
      () => _native.listObjects(prefix: path, maxKeys: 1),
    );
    return page.objects.any((object) => object.key == path) ||
        page.commonPrefixes.any((prefix) => prefix == path);
  }

  /// 递归列出前缀下全部对象（含子目录），返回完整对象元数据。
  Future<List<OssNativeObject>> listAllObjects(
    String path,
    UserSession session,
  ) async {
    await _ensureConfigured(session);
    final objects = <OssNativeObject>[];
    String? marker;
    do {
      final page = await _platform(
        () => _native.listObjects(
          prefix: path,
          marker: marker,
          maxKeys: 1000,
        ),
      );
      objects.addAll(page.objects);
      marker = page.isTruncated ? page.nextMarker : null;
      if (page.isTruncated && (marker == null || marker.isEmpty)) {
        throw AppError('OSS 分页响应缺少下一页标识', code: 'OSS_INVALID_RESPONSE');
      }
    } while (marker != null && marker.isNotEmpty);
    return objects;
  }

  /// 点前缀条目（回收站 .trash/、相册 .gallery/、.DS_Store 等系统或
  /// 内部对象）在文件浏览与目录统计中默认隐藏。
  bool _isHiddenEntry(String key, String prefix) =>
      key.length > prefix.length &&
      key.substring(prefix.length).startsWith('.');
}
