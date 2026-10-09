import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// 本地磁盘文档缓存（PDF 等大文档落盘预览）。与 DiskImageCache 相同的
/// LRU 淘汰机制；任何读写失败都视为缓存不存在，由调用方直接回源 OSS。
class DiskDocumentCache {
  DiskDocumentCache({
    Directory? Function()? rootResolver,
    int byteLimit = 512 * 1024 * 1024,
  })  : _rootResolver = rootResolver,
        _byteLimit = byteLimit;

  /// 生产单例，使用平台临时缓存目录。
  static final DiskDocumentCache instance = DiskDocumentCache();

  static const _directoryName = 'pdd_document_cache';

  final Directory? Function()? _rootResolver;
  final int _byteLimit;
  Directory? _directory;
  Map<String, _DocumentCacheEntry>? _index;

  /// 缓存键只允许出现在文件名安全的位置，统一转成十六进制摘要。
  static String cacheKey({
    required String namespace,
    required String path,
    required String versionToken,
  }) {
    final raw = '$namespace|$path|$versionToken';
    return sha256.convert(utf8.encode(raw)).toString();
  }

  /// 缓存命中时返回可直接打开的本地文件，并刷新 LRU 使用时间。
  Future<File?> get(String key) async {
    try {
      await _ensureReady();
      final directory = _directory;
      final index = _index;
      if (directory == null || index == null) return null;
      final file = File('${directory.path}${Platform.pathSeparator}$key');
      final entry = index[file.path];
      if (entry == null) return null;
      if (!await file.exists()) {
        index.remove(file.path);
        return null;
      }
      final now = DateTime.now();
      entry.lastUsed = now;
      unawaited(_touch(file, now));
      return file;
    } catch (_) {
      return null;
    }
  }

  /// 创建用于流式写入的临时文件；commit 成功后才进入缓存索引。
  Future<File?> createTemporaryFile() async {
    try {
      await _ensureReady();
      final directory = _directory;
      if (directory == null) return null;
      final temp = File(
        '${directory.path}${Platform.pathSeparator}'
        '${DateTime.now().microsecondsSinceEpoch}.part',
      );
      await temp.create(exclusive: true);
      return temp;
    } catch (_) {
      return null;
    }
  }

  /// 临时文件写入完成后落定到正式缓存条目并执行 LRU 驱逐。
  Future<File?> commit(String key, File temporary) async {
    try {
      await _ensureReady();
      final directory = _directory;
      final index = _index;
      if (directory == null || index == null) return null;
      final target = File('${directory.path}${Platform.pathSeparator}$key');
      final size = await temporary.length();
      if (size <= 0) {
        unawaited(_deleteQuietly(temporary));
        return null;
      }
      try {
        await temporary.rename(target.path);
      } on FileSystemException {
        // rename 跨设备或目标被占用时退化为复制后删除。
        await temporary.copy(target.path);
        unawaited(_deleteQuietly(temporary));
      }
      index[target.path] = _DocumentCacheEntry(
        size: size,
        lastUsed: DateTime.now(),
      );
      unawaited(_evictIfNeeded());
      return target;
    } catch (_) {
      unawaited(_deleteQuietly(temporary));
      return null;
    }
  }

  /// 写入失败时清理临时文件，不留垃圾。
  Future<void> discard(File temporary) async {
    await _deleteQuietly(temporary);
  }

  Future<void> _ensureReady() async {
    if (_index != null) return;
    final directory = await _openDirectory();
    _directory = directory;
    final index = <String, _DocumentCacheEntry>{};
    if (directory != null) {
      await for (final entity in directory.list()) {
        if (entity is! File || entity.path.endsWith('.part')) continue;
        try {
          final stat = await entity.stat();
          if (stat.size <= 0) {
            unawaited(_deleteQuietly(entity));
            continue;
          }
          index[entity.path] =
              _DocumentCacheEntry(size: stat.size, lastUsed: stat.modified);
        } catch (_) {
          // 单个文件状态读取失败时跳过该条目。
        }
      }
    }
    _index = index;
  }

  Future<Directory?> _openDirectory() async {
    try {
      final root = _rootResolver?.call() ?? await getTemporaryDirectory();
      final directory = Directory(
        '${root.path}${Platform.pathSeparator}$_directoryName',
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

  Future<void> _evictIfNeeded() async {
    final index = _index;
    if (index == null) return;
    int total() => index.values.fold(0, (sum, entry) => sum + entry.size);
    if (total() <= _byteLimit) return;
    final entries = index.entries.toList()
      ..sort((left, right) =>
          left.value.lastUsed.compareTo(right.value.lastUsed));
    for (final entry in entries) {
      if (total() <= _byteLimit) return;
      await _deleteQuietly(File(entry.key));
      index.remove(entry.key);
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删除失败时仍从索引移除，避免淘汰循环卡死。
    }
  }
}

class _DocumentCacheEntry {
  _DocumentCacheEntry({required this.size, required this.lastUsed});

  final int size;
  DateTime lastUsed;
}
