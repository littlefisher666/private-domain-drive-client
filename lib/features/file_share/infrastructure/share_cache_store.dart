import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/errors/app_error.dart';
import '../../../shared/cache/local_cache_store.dart';
import '../../workspace/domain/file_item.dart';

/// 分享专用临时缓存：按对象路径与版本分目录，并保留原始文件名，
/// 确保系统分享面板收到的文件名正确。
///
/// 目录结构：
/// `pdd_share_cache/<sha256(objectPath|versionToken)>/<原始文件名>`
class ShareCacheStore implements LocalCacheStore {
  ShareCacheStore({
    Directory? Function()? rootResolver,
    this.retention = defaultRetention,
    this.capacityLimitBytes = defaultCapacityLimitBytes,
  }) : _rootResolver = rootResolver;

  static const _directoryName = 'pdd_share_cache';
  static const defaultRetention = Duration(days: 7);
  static const defaultCapacityLimitBytes = 2 * 1024 * 1024 * 1024;

  final Directory? Function()? _rootResolver;
  final Duration retention;
  final int capacityLimitBytes;

  Directory? _root;

  /// 缓存目录名只包含十六进制摘要，避免对象路径中的特殊字符进入路径。
  static String cacheDirectoryName(FileItem item) {
    final raw = '${item.path}|${item.objectVersionToken}';
    return sha256.convert(utf8.encode(raw)).toString();
  }

  /// 保留原始文件名（含扩展名）供接收方识别，仅替换路径分隔符等
  /// 本地文件系统非法字符；超长名称保留扩展名并截断主体。
  static String sanitizeFileName(String rawName) {
    final lastSegment = rawName.replaceAll('\\', '/').split('/').last.trim();
    final buffer = StringBuffer();
    for (final rune in lastSegment.runes) {
      final invalid = rune < 0x20 ||
          rune == 0x00 ||
          rune == 0x22 ||
          rune == 0x2a || // *
          rune == 0x2f || // /
          rune == 0x3a || // :
          rune == 0x3c || // <
          rune == 0x3e || // >
          rune == 0x3f || // ?
          rune == 0x5c || // \
          rune == 0x7c; // |
      buffer.write(invalid ? '_' : String.fromCharCode(rune));
    }
    final sanitized = buffer.toString();
    if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
      return 'file';
    }
    if (utf8.encode(sanitized).length <= 200) {
      return sanitized;
    }
    final dot = sanitized.lastIndexOf('.');
    final extension =
        dot > 0 && sanitized.length - dot <= 20 ? sanitized.substring(dot) : '';
    final base = extension.isEmpty
        ? sanitized
        : sanitized.substring(0, sanitized.length - extension.length);
    return '${String.fromCharCodes(base.runes.take(120))}$extension';
  }

  /// 分享副本的最终路径；父目录不存在时创建。
  Future<File> fileFor(FileItem item) async {
    final root = await _ensureRoot();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}${cacheDirectoryName(item)}',
    );
    await directory.create(recursive: true);
    return File(
      '${directory.path}${Platform.pathSeparator}'
      '${sanitizeFileName(item.name)}',
    );
  }

  /// 命中时返回可用副本并刷新最近访问时间；大小不一致视为未命中。
  Future<File?> lookup(FileItem item) async {
    try {
      final file = await fileFor(item);
      if (!await file.exists()) return null;
      final length = await file.length();
      final expected = item.size;
      if (length <= 0 || (expected != null && expected != length)) {
        await _deleteQuietly(file);
        return null;
      }
      await _touch(file);
      return file;
    } catch (_) {
      return null;
    }
  }

  Future<File> temporaryFileFor(File target) async {
    final temporary = File('${target.path}.part');
    await temporary.parent.create(recursive: true);
    return temporary;
  }

  /// 下载成功后落定缓存；跨设备 rename 失败时退化为复制后删除。
  Future<File> commit(File temporary, File target) async {
    try {
      await temporary.rename(target.path);
    } on FileSystemException {
      await temporary.copy(target.path);
      await _deleteQuietly(temporary);
    }
    await _touch(target);
    return target;
  }

  Future<void> discard(File temporary) => _deleteQuietly(temporary);

  /// 删除超期文件，并在总容量超限时按最近访问时间从旧到新淘汰。
  /// 跳过 `.part` 临时文件与 [keepPaths] 中的待分享文件，仅作用于本地缓存。
  Future<int> clean({
    Set<String> keepPaths = const <String>{},
    DateTime? now,
  }) async {
    final root = await _tryRoot();
    if (root == null) return 0;
    final current = now ?? DateTime.now();
    final cutoff = current.subtract(retention);
    final entries = <_CacheEntry>[];
    try {
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is! File || entity.path.endsWith('.part')) continue;
        try {
          final stat = await entity.stat();
          if (stat.size <= 0) {
            await _deleteQuietly(entity);
            continue;
          }
          entries.add(_CacheEntry(
            file: entity,
            size: stat.size,
            lastModified: stat.modified,
          ));
        } catch (_) {
          // 单个文件状态读取失败时跳过该条目。
        }
      }
    } catch (_) {
      return 0;
    }

    var removed = 0;
    final retained = <_CacheEntry>[];
    for (final entry in entries) {
      if (entry.lastModified.isBefore(cutoff) &&
          !keepPaths.contains(entry.file.path)) {
        await _deleteQuietly(entry.file);
        removed++;
      } else {
        retained.add(entry);
      }
    }

    var total = retained.fold<int>(0, (sum, entry) => sum + entry.size);
    if (total > capacityLimitBytes) {
      retained.sort(
        (left, right) => left.lastModified.compareTo(right.lastModified),
      );
      for (final entry in retained) {
        if (total <= capacityLimitBytes) break;
        if (keepPaths.contains(entry.file.path)) continue;
        await _deleteQuietly(entry.file);
        total -= entry.size;
        removed++;
      }
    }

    await _pruneEmptyDirectories(root);
    return removed;
  }

  Future<Directory?> _tryRoot() async {
    try {
      return await _ensureRoot();
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _ensureRoot() async {
    final existing = _root;
    if (existing != null) return existing;
    try {
      final base = _rootResolver?.call() ?? await getTemporaryDirectory();
      final directory = Directory(
        '${base.path}${Platform.pathSeparator}$_directoryName',
      );
      await directory.create(recursive: true);
      _root = directory;
      return directory;
    } catch (_) {
      throw AppError(
        '分享缓存目录不可用',
        code: 'SHARE_CACHE_DIR_UNAVAILABLE',
      );
    }
  }

  Future<void> _pruneEmptyDirectories(Directory root) async {
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        try {
          if (await entity.list().isEmpty) await entity.delete();
        } catch (_) {
          // 目录非空或删除失败时保留。
        }
      }
    } catch (_) {
      // 清理失败不影响后续分享。
    }
  }

  /// 分享临时文件当前占用。
  @override
  Future<int> sizeBytes() async {
    final root = await _tryRoot();
    if (root == null) return 0;
    var total = 0;
    try {
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } catch (_) {
          // 单个文件读取失败时跳过。
        }
      }
    } catch (_) {
      return total;
    }
    return total;
  }

  /// 删除全部分享临时文件并清理空目录。
  @override
  Future<void> clear() async {
    final root = await _tryRoot();
    if (root == null) return;
    try {
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is File) await _deleteQuietly(entity);
      }
    } catch (_) {
      // 遍历失败时保留未能删除的文件，下次清理继续处理。
    }
    await _pruneEmptyDirectories(root);
  }

  Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {
      // touch 失败仅影响淘汰顺序。
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删除失败时忽略，避免清理流程中断。
    }
  }
}

class _CacheEntry {
  const _CacheEntry({
    required this.file,
    required this.size,
    required this.lastModified,
  });

  final File file;
  final int size;
  final DateTime lastModified;
}
