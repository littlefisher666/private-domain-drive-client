import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/errors/app_error.dart';
import '../domain/gallery_config.dart';
import 'gallery_database.dart';

/// 原图缓存管理：专用缓存目录 + SQLite 记录，是云朵角标与查看器
/// 秒开判断的唯一依据。清理仅删除本地文件与记录，不触碰 OSS 数据。
class OriginalCacheStore {
  OriginalCacheStore(this._database);

  final GalleryDatabase _database;
  Directory? _directory;

  /// 原图缓存文件路径（sha256 风格的稳定文件名由调用方保证唯一，
  /// 这里直接使用对象 key 的转义形式）。
  Future<File> fileFor(String objectKey) async {
    final directory = await _ensureDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}${_safeFileName(objectKey)}',
    );
  }

  /// 是否存在有效缓存记录（角标与秒开判断的唯一依据）。
  Future<bool> isCached(String objectKey) =>
      _database.hasOriginalCache(objectKey);

  Future<File?> resolveCachedFile(String objectKey) async {
    final record = await _database.readCacheRecord(objectKey);
    if (record == null) return null;
    final file = File(record.filePath);
    if (!await file.exists()) {
      // 记录存在但文件丢失：清理记录，让角标恢复到未缓存状态。
      await _database.removeCacheRecords(<String>[objectKey]);
      return null;
    }
    await _database.touchCacheRecord(objectKey);
    return file;
  }

  /// 下载完成后写入缓存记录。
  Future<void> recordCached({
    required String objectKey,
    required File file,
    required int size,
  }) async {
    await _database.writeCacheRecord(
      key: objectKey,
      filePath: file.path,
      size: size,
    );
  }

  /// 删除指定条目的缓存记录与本地文件（媒体删除联动）。
  Future<void> removeCached(Iterable<String> objectKeys) async {
    for (final key in objectKeys) {
      final record = await _database.readCacheRecord(key);
      if (record != null) {
        try {
          final file = File(record.filePath);
          if (await file.exists()) await file.delete();
        } catch (error) {
          debugPrint('[gallery] 缓存文件删除失败: $error');
        }
      }
    }
    await _database.removeCacheRecords(objectKeys);
  }

  /// 按时间清理：最后访问超过配置天数的条目（App 启动时）。
  Future<int> cleanExpired() async {
    final cutoff = DateTime.now().subtract(
      const Duration(days: GalleryConfig.cacheExpireDays),
    );
    final expired = await _database.readExpiredCacheRecords(cutoff);
    return _removeEntries(expired);
  }

  /// 按容量清理：总容量超过上限时按 LRU 清理至阈值以下（下载前预检）。
  Future<int> cleanOverCapacity() async {
    var total = await _database.cachedTotalSize();
    if (total <= GalleryConfig.cacheCapacityLimit) return 0;
    final records = await _database.readCacheRecordsByLru();
    var removed = 0;
    for (final record in records) {
      if (total <= GalleryConfig.cacheCapacityTarget) break;
      removed += await _removeEntries(<OriginalCacheRecord>[record]);
      total -= record.size;
    }
    return removed;
  }

  Future<int> _removeEntries(Iterable<OriginalCacheRecord> records) async {
    var removed = 0;
    for (final record in records) {
      try {
        final file = File(record.filePath);
        if (await file.exists()) await file.delete();
        removed++;
      } catch (error) {
        // 删除失败时仍移除记录，避免清理循环卡死。
        debugPrint('[gallery] 缓存清理删除文件失败: $error');
      }
    }
    await _database.removeCacheRecords(records.map((record) => record.key));
    return removed;
  }

  /// 读取本地缓存文件，未命中返回 null（查看器秒开入口）。
  Future<File?> readOriginal(String objectKey) => resolveCachedFile(objectKey);

  Future<void> validateIntegrity() async {
    final records = await _database.readCacheRecordsByLru();
    final broken = <OriginalCacheRecord>[];
    for (final record in records) {
      if (!await File(record.filePath).exists()) broken.add(record);
    }
    if (broken.isNotEmpty) {
      await _database.removeCacheRecords(broken.map((record) => record.key));
    }
  }

  Future<Directory> _ensureDirectory() async {
    final existing = _directory;
    if (existing != null) return existing;
    try {
      final support = await getApplicationSupportDirectory();
      final directory = Directory(
        '${support.path}${Platform.pathSeparator}pdd_original_cache',
      );
      await directory.create(recursive: true);
      _directory = directory;
      return directory;
    } catch (error) {
      debugPrint('[gallery] 原图缓存目录不可用: $error');
      throw AppError('原图缓存目录不可用',
          code: 'GALLERY_CACHE_DIR_UNAVAILABLE');
    }
  }
}

String _safeFileName(String objectKey) {
  final builder = StringBuffer();
  for (final code in objectKey.codeUnits) {
    if (code >= 48 && code <= 57 ||
        code >= 65 && code <= 90 ||
        code >= 97 && code <= 122 ||
        code == 0x2e || // .
        code == 0x2d) {
      // -
      builder.writeCharCode(code);
    } else {
      builder.write(code.toRadixString(16).padLeft(2, '0'));
    }
  }
  return builder.toString();
}
