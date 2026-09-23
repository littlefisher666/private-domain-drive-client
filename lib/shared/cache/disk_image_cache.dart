import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

enum DiskImageCacheKind { thumbnails, previews }

/// 本地磁盘图片缓存。缩略图与预览共用同一套读写与 LRU 淘汰机制，
/// 任何读写失败都视为缓存不存在，由调用方直接回源 OSS。
class DiskImageCache {
  DiskImageCache({
    Directory? Function()? rootResolver,
    int thumbnailByteLimit = 500 * 1024 * 1024,
    int previewByteLimit = 1024 * 1024 * 1024,
  })  : _rootResolver = rootResolver,
        _byteLimits = {
          DiskImageCacheKind.thumbnails: thumbnailByteLimit,
          DiskImageCacheKind.previews: previewByteLimit,
        };

  /// 生产单例，使用平台临时缓存目录。
  static final DiskImageCache instance = DiskImageCache();

  final Directory? Function()? _rootResolver;
  final Map<DiskImageCacheKind, int> _byteLimits;
  final Map<DiskImageCacheKind, Directory?> _directories = {};
  final Map<DiskImageCacheKind, Map<String, _DiskCacheEntry>> _indexes = {};

  /// 缓存键只允许出现在文件名安全的位置，统一转成十六进制摘要。
  static String cacheKey({
    required String namespace,
    required String path,
    required String versionToken,
    required String process,
  }) {
    final raw = '$namespace|$path|$versionToken|$process';
    return sha256.convert(utf8.encode(raw)).toString();
  }

  Future<List<int>?> read(DiskImageCacheKind kind, String key) async {
    try {
      final file = await _fileFor(kind, key);
      if (file == null) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      final now = DateTime.now();
      _indexes[kind]?[file.path]?.lastUsed = now;
      unawaited(_touch(file, now));
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(DiskImageCacheKind kind, String key, List<int> bytes) async {
    if (bytes.isEmpty) return;
    try {
      final file = await _fileFor(kind, key);
      if (file == null) return;
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
      _indexes[kind]?[file.path] =
          _DiskCacheEntry(size: bytes.length, lastUsed: DateTime.now());
      await _evictIfNeeded(kind);
    } catch (_) {
      // 缓存写入失败不影响本次内容展示。
    }
  }

  Future<File?> _fileFor(DiskImageCacheKind kind, String key) async {
    await _ensureReady(kind);
    final directory = _directories[kind];
    if (directory == null) return null;
    return File('${directory.path}${Platform.pathSeparator}$key');
  }

  Future<void> _ensureReady(DiskImageCacheKind kind) async {
    if (_indexes.containsKey(kind)) return;
    final directory = await _openDirectory(kind);
    _directories[kind] = directory;
    final index = <String, _DiskCacheEntry>{};
    if (directory != null) {
      await for (final entity in directory.list()) {
        if (entity is! File || entity.path.endsWith('.tmp')) continue;
        try {
          final stat = await entity.stat();
          if (stat.size <= 0) continue;
          index[entity.path] =
              _DiskCacheEntry(size: stat.size, lastUsed: stat.modified);
        } catch (_) {
          // 单个文件状态读取失败时跳过该条目。
        }
      }
    }
    _indexes[kind] = index;
  }

  Future<Directory?> _openDirectory(DiskImageCacheKind kind) async {
    try {
      final root = _rootResolver?.call() ?? await getTemporaryDirectory();
      final directory = Directory(
        '${root.path}${Platform.pathSeparator}'
        'pdd_image_cache${Platform.pathSeparator}${kind.name}',
      );
      await directory.create(recursive: true);
      return directory;
    } catch (_) {
      return null;
    }
  }

  Future<void> _touch(File file, DateTime when) async {
    try {
      await file.setLastModified(when);
    } catch (_) {
      // touch 失败仅影响淘汰顺序。
    }
  }

  Future<void> _evictIfNeeded(DiskImageCacheKind kind) async {
    final index = _indexes[kind];
    if (index == null) return;
    final limit = _byteLimits[kind]!;
    int total() => index.values.fold(0, (sum, entry) => sum + entry.size);
    if (total() <= limit) return;
    final entries = index.entries.toList()
      ..sort((left, right) =>
          left.value.lastUsed.compareTo(right.value.lastUsed));
    for (final entry in entries) {
      if (total() <= limit) return;
      try {
        await File(entry.key).delete();
      } catch (_) {
        // 删除失败时仍从索引移除，避免淘汰循环卡死。
      }
      index.remove(entry.key);
    }
  }
}

class _DiskCacheEntry {
  _DiskCacheEntry({required this.size, required this.lastUsed});

  final int size;
  DateTime lastUsed;
}
