import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:private_domain_oss/private_domain_oss.dart';

import '../../../core/errors/app_error.dart';
import '../../auth/domain/user_session.dart';
import '../../workspace/infrastructure/oss_client.dart';
import '../domain/gallery_config.dart';
import '../domain/photo_date_hints.dart';
import '../domain/photo_entry.dart';
import '../domain/photo_manifest.dart';
import 'gallery_database.dart';
import 'media_bridge.dart';

const _imageExtensions = <String>{
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp',
};
const _videoExtensions = <String>{
  'mp4', 'mov', 'm4v', 'mkv', 'avi', 'webm', '3gp',
};

bool isImageFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return _imageExtensions.contains(name.substring(dot + 1).toLowerCase());
}

bool isVideoFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return _videoExtensions.contains(name.substring(dot + 1).toLowerCase());
}

bool isMediaFileName(String name) =>
    isImageFileName(name) || isVideoFileName(name);

PhotoMediaType mediaTypeOf(String name) =>
    isVideoFileName(name) ? PhotoMediaType.video : PhotoMediaType.image;

/// 清单写入结果：成功，或冲突超限需要标记待修复。
enum ManifestWriteResult { success, conflictExceeded }

/// 照片索引仓库：OSS 清单对象（读-改-写 + ETag 乐观并发）
/// 与本地 SQLite 副本之间的同步。
class PhotoIndexRepository {
  PhotoIndexRepository({
    required OssClient ossClient,
    required GalleryDatabase database,
    MediaBridge? mediaBridge,
  })  : _ossClient = ossClient,
        _database = database,
        _mediaBridge = mediaBridge ?? MediaBridge();

  final OssClient _ossClient;
  final GalleryDatabase _database;
  final MediaBridge _mediaBridge;

  String manifestKey(UserSession session) =>
      '${session.rootPrefix}${GalleryConfig.manifestRelativeKey}';

  String thumbKeyFor(UserSession session, String objectKey) =>
      '${session.rootPrefix}${GalleryConfig.thumbRelativePrefix}'
      '$objectKey.jpg';

  /// 读取 OSS 清单对象。清单不存在返回 null；JSON 损坏抛出
  /// [FormatException]，由调用方标记待修复。
  Future<(PhotoManifest, String)?> loadManifest(UserSession session) async {
    final key = manifestKey(session);
    final page = await _ossClient.listAllObjects(key, session);
    if (page.isEmpty) return null;
    final bytes = await _ossClient.download(
      key,
      session,
      maxBytes: GalleryConfig.manifestMaxBytes,
    );
    final manifest = PhotoManifest.decode(utf8.decode(bytes));
    final etag = page.firstWhere((object) => object.key == key).etag;
    return (manifest, etag ?? '');
  }

  /// 读-改-写整个清单对象：读取时记录 ETag，写入前复查；
  /// ETag 变化说明有并发写入，退避后重试，超限返回 [ManifestWriteResult.conflictExceeded]。
  Future<ManifestWriteResult> updateManifest(
    UserSession session,
    PhotoManifest Function(PhotoManifest manifest) mutate,
  ) async {
    for (var attempt = 0;
        attempt < GalleryConfig.manifestWriteMaxAttempts;
        attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(
          Duration(milliseconds: 200 * pow(2, attempt).round() + Random().nextInt(150)),
        );
      }
      PhotoManifest current;
      String currentEtag;
      try {
        final loaded = await loadManifest(session);
        currentEtag = loaded?.$2 ?? '';
        current = loaded?.$1 ??
            PhotoManifest(
              version: 0,
              scannedAt: null,
              needsRepair: false,
              entries: const <PhotoEntry>[],
              formatVersion: PhotoManifest.currentFormatVersion,
            );
      } on FormatException {
        return ManifestWriteResult.conflictExceeded;
      }
      var next = mutate(current);
      if (next.version <= current.version) {
        next = PhotoManifest(
          version: current.version + 1,
          scannedAt: next.scannedAt,
          needsRepair: next.needsRepair,
          entries: next.entries,
          formatVersion: next.formatVersion,
        );
      }
      // 写入前复查 ETag：变化说明期间有并发写入，退避重试。
      // （原生上传不支持条件写，采用读后复查缩小竞态窗口，
      // 残余冲突由待修复全量扫描自愈。）
      try {
        final latest = await loadManifest(session);
        if (latest != null && latest.$2 != currentEtag) {
          continue;
        }
      } on FormatException {
        return ManifestWriteResult.conflictExceeded;
      } catch (_) {
        // 复查失败时按原计划写入；极端冲突由全量扫描兜底。
      }
      await _ossClient.uploadText(manifestKey(session), next.encode(), session);
      return ManifestWriteResult.success;
    }
    return ManifestWriteResult.conflictExceeded;
  }

  /// 全量扫描建索引：递归列举全部对象、过滤媒体类型、解析拍摄时间，
  /// 写入本地副本并同步生成 OSS 清单对象。扫描结果与清单写入失败
  /// 不抛出异常，由调用方根据返回的标记决定提示策略。
  Future<PhotoManifest> fullScan(
    UserSession session, {
    void Function(int processed, int total)? onProgress,
  }) async {
    final root = session.rootPrefix;
    final galleryPrefix = '$root.gallery/';
    final trashPrefix = '$root.trash/';

    final objects = await _ossClient.listAllObjects(root, session);
    final mediaObjects = <OssNativeObject>[];
    for (final object in objects) {
      final key = object.key;
      if (key.endsWith('/')) continue;
      if (key.startsWith(galleryPrefix)) continue;
      if (key.startsWith(trashPrefix)) continue;
      final name = key.substring(key.lastIndexOf('/') + 1);
      if (!isMediaFileName(name)) continue;
      mediaObjects.add(object);
    }
    onProgress?.call(0, mediaObjects.length);

    // 断点续扫：上次扫描（含中途退出）已写入本地副本的条目，
    // 若对象大小与修改时间未变则直接复用，跳过 EXIF 请求。
    final existingEntries = <String, PhotoEntry>{
      for (final entry in await _database.readAllEntries()) entry.key: entry,
    };
    bool reusable(PhotoEntry entry, OssNativeObject object) {
      if (entry.size != object.size ||
          entry.modifiedMs != object.lastModifiedMilliseconds) {
        return false;
      }
      // 早期版本把无 EXIF 条目的拍摄时间直接写成上传时间；拍摄时间
      // 与上传时间一致的条目重扫一次，让文件名/目录日期推断生效。
      return entry.takenAt.millisecondsSinceEpoch !=
          (object.lastModifiedMilliseconds ??
              entry.takenAt.millisecondsSinceEpoch);
    }

    // 工作池模式：N 个常驻 worker 领完一个立刻领下一个，避免
    // 分批栅栏下单个慢请求阻塞整批。Dart 单线程模型下 cursor
    // 自增与 entries 追加不存在数据竞争。
    final entries = <PhotoEntry>[];
    var cursor = 0;
    var processed = 0;
    Future<void> worker() async {
      while (cursor < mediaObjects.length) {
        final object = mediaObjects[cursor++];
        final cached = existingEntries[object.key];
        final reused = cached != null && reusable(cached, object);
        final entry =
            reused ? cached : await _scanEntry(session, object, cached: cached);
        if (entry != null) {
          entries.add(entry);
          if (!reused) {
            // 中途退出也能保留已解析条目，下次扫描直接复用。
            await _database.upsertEntries(<PhotoEntry>[entry]);
          }
        }
        onProgress?.call(++processed, mediaObjects.length);
      }
    }

    await Future.wait(List.generate(
      min(GalleryConfig.scanExifConcurrency, mediaObjects.length),
      (_) => worker(),
    ));
    entries.sort((left, right) => right.takenAt.compareTo(left.takenAt));

    final manifest = PhotoManifest(
      version: 0,
      scannedAt: DateTime.now(),
      needsRepair: false,
      entries: entries,
      formatVersion: PhotoManifest.currentFormatVersion,
    );
    await _database.replaceEntries(entries);
    await _database.writeIndexMeta(PhotoIndexMeta(
      version: manifest.version,
      scannedAt: manifest.scannedAt,
      needsRepair: false,
    ));

    // 清单写入失败不影响本地副本；下次进入相册页会再次尝试同步。
    try {
      final writeResult = await updateManifest(session, (current) => manifest);
      if (writeResult == ManifestWriteResult.conflictExceeded) {
        await _database.writeIndexMeta(PhotoIndexMeta(
          version: manifest.version,
          scannedAt: manifest.scannedAt,
          needsRepair: true,
        ));
      }
    } catch (error) {
      debugPrint('[gallery] 清单对象写入失败: $error');
      await _database.writeIndexMeta(PhotoIndexMeta(
        version: manifest.version,
        scannedAt: manifest.scannedAt,
        needsRepair: true,
      ));
    }
    final finalMeta = await _database.readIndexMeta();
    return PhotoManifest(
      version: manifest.version,
      scannedAt: manifest.scannedAt,
      needsRepair: finalMeta?.needsRepair ?? false,
      entries: entries,
      formatVersion: manifest.formatVersion,
    );
  }

  /// 单条目扫描：限流或瞬时失败时退避重试，避免高并发下
  /// 把照片静默跳过出索引。[cached] 用于对象未变化的重扫保留
  /// 已有缩略图映射，避免重复截帧上传。
  Future<PhotoEntry?> _scanEntry(
    UserSession session,
    OssNativeObject object, {
    PhotoEntry? cached,
  }) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await _scanEntryOnce(session, object, cached: cached);
      } catch (error) {
        if (attempt >= 2) {
          debugPrint('[gallery] 扫描对象 ${object.key} 失败: $error');
          return null;
        }
        await Future<void>.delayed(Duration(milliseconds: 500 << attempt));
      }
    }
  }

  Future<PhotoEntry?> _scanEntryOnce(
    UserSession session,
    OssNativeObject object, {
    PhotoEntry? cached,
  }) async {
    final key = object.key;
    final directory = key.substring(0, key.lastIndexOf('/') + 1);
    final name = key.substring(key.lastIndexOf('/') + 1);
    final mediaType = mediaTypeOf(name);
    final modified = object.lastModifiedMilliseconds;
    final fileTime = modified == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true).toLocal();
    // 仅当对象未变化时保留旧缩略图映射；对象被覆盖说明缩略图也已重传。
    final thumbKey = cached != null &&
            cached.size == object.size &&
            cached.modifiedMs == modified
        ? cached.thumbKey
        : null;
    if (mediaType == PhotoMediaType.image) {
      final exif = await _ossClient.readImageExif(key, session);
      return PhotoEntry(
        key: key,
        mediaType: mediaType,
        takenAt: exif.takenAt ??
            inferTakenAtFromName(fileName: name, directory: directory) ??
            fileTime,
        size: object.size,
        directory: directory,
        thumbKey: thumbKey,
        modifiedMs: modified,
        width: exif.width,
        height: exif.height,
        latitude: exif.latitude,
        longitude: exif.longitude,
      );
    }
    return PhotoEntry(
      key: key,
      mediaType: mediaType,
      takenAt:
          inferTakenAtFromName(fileName: name, directory: directory) ??
              fileTime,
      size: object.size,
      directory: directory,
      thumbKey: thumbKey,
      modifiedMs: modified,
    );
  }

  /// 上传成功后的索引增量更新。
  ///
  /// 视频条目的 [thumbLocalPath] 为上传前截帧的本地临时 JPEG；上传缩略图
  /// 对象失败不阻塞索引更新，条目标记为无缩略图。
  Future<PhotoEntry?> addUploadedMedia(
    UserSession session, {
    required String objectPath,
    required String localPath,
    String? thumbLocalPath,
  }) async {
    final name = objectPath.substring(objectPath.lastIndexOf('/') + 1);
    if (!isMediaFileName(name)) return null;
    final directory = objectPath.substring(0, objectPath.lastIndexOf('/') + 1);
    final mediaType = mediaTypeOf(name);
    final localFile = File(localPath);
    final fileTime = await localFile.lastModified();

    String? thumbKey;
    if (thumbLocalPath != null) {
      try {
        thumbKey = thumbKeyFor(session, objectPath);
        await _ossClient.uploadFile(
          thumbKey,
          thumbLocalPath,
          session,
          taskId: 'thumb-${DateTime.now().microsecondsSinceEpoch}',
        );
      } catch (error) {
        debugPrint('[gallery] 缩略图上传失败（不阻塞）: $error');
        thumbKey = null;
      }
    }

    DateTime takenAt = fileTime;
    int? width;
    int? height;
    double? latitude;
    double? longitude;
    if (mediaType == PhotoMediaType.image) {
      try {
        final exif = await _ossClient.readLocalImageExif(localFile);
        takenAt = exif.takenAt ??
            inferTakenAtFromName(
              fileName: name,
              directory: directory,
            ) ??
            fileTime;
        width = exif.width;
        height = exif.height;
        latitude = exif.latitude;
        longitude = exif.longitude;
      } catch (_) {
        takenAt = inferTakenAtFromName(
              fileName: name,
              directory: directory,
            ) ??
            fileTime;
      }
    } else {
      try {
        takenAt = await _mediaBridge.readVideoTakenAt(localPath) ??
            inferTakenAtFromName(
              fileName: name,
              directory: directory,
            ) ??
            fileTime;
      } catch (_) {
        takenAt = inferTakenAtFromName(
              fileName: name,
              directory: directory,
            ) ??
            fileTime;
      }
    }

    int size;
    try {
      size = await localFile.length();
    } catch (_) {
      size = 0;
    }

    final entry = PhotoEntry(
      key: objectPath,
      mediaType: mediaType,
      takenAt: takenAt,
      size: size,
      directory: directory,
      thumbKey: thumbKey,
      modifiedMs: fileTime.millisecondsSinceEpoch,
      width: width,
      height: height,
      latitude: latitude,
      longitude: longitude,
      device: _deviceName(),
    );

    await _database.upsertEntries(<PhotoEntry>[entry]);
    try {
      final result = await updateManifest(session, (current) {
        final kept = current.entries
            .where((candidate) => candidate.key != objectPath)
            .toList();
        kept.add(entry);
        kept.sort((left, right) => right.takenAt.compareTo(left.takenAt));
        return PhotoManifest(
          version: current.version,
          scannedAt: current.scannedAt,
          needsRepair: false,
          entries: kept,
          formatVersion: current.formatVersion,
        );
      });
      if (result == ManifestWriteResult.conflictExceeded) {
        await _markNeedsRepair();
      }
    } catch (error) {
      debugPrint('[gallery] 索引增量更新失败: $error');
    }
    return entry;
  }

  /// 存量缩略图补齐：为无缩略图映射的视频请求 OSS 服务端截帧；为
  /// 超过 OSS 图片处理大小限制的图片下载原图、本地缩放后上传，均存
  /// 为独立缩略图对象。工作池并发处理；单条超时或失败跳过（不阻塞
  /// 其余）。成功条目先更新本地副本，最后一次性写回清单。返回补齐
  /// 成功的条目数。
  Future<int> backfillMissingThumbnails(
    UserSession session, {
    void Function(PhotoEntry entry)? onEntryUpdated,
  }) async {
    final all = await _database.readAllEntries();
    final missing = all
        .where((entry) =>
            entry.thumbKey == null &&
            (entry.mediaType == PhotoMediaType.video ||
                (entry.mediaType == PhotoMediaType.image &&
                    entry.size > GalleryConfig.oversizedImageLimit)))
        .toList();
    if (missing.isEmpty) return 0;

    final updated = <PhotoEntry>[];
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= missing.length) return;
        final entry = missing[index];
        try {
          // 单条整体限时：任一环节（截帧/下载/缩放/上传）挂起时放弃
          // 该条继续队列，避免一个无响应请求堵死后续全部条目。
          final next = await _backfillEntryWithRetry(session, entry)
              .timeout(GalleryConfig.thumbBackfillEntryTimeout,
                  onTimeout: () => null);
          if (next == null) continue;
          updated.add(next);
          await _database.upsertEntries(<PhotoEntry>[next]);
          onEntryUpdated?.call(next);
        } catch (error) {
          debugPrint('[gallery] 缩略图补齐失败 ${entry.key}: $error');
        }
      }
    }

    await Future.wait(List.generate(
      min(GalleryConfig.thumbBackfillConcurrency, missing.length),
      (_) => worker(),
    ));

    if (updated.isNotEmpty) {
      try {
        final result = await updateManifest(session, (current) {
          final byKey = <String, PhotoEntry>{
            for (final candidate in current.entries) candidate.key: candidate,
          };
          for (final entry in updated) {
            byKey[entry.key] = entry;
          }
          final kept = byKey.values.toList()
            ..sort((left, right) => right.takenAt.compareTo(left.takenAt));
          return PhotoManifest(
            version: current.version,
            scannedAt: current.scannedAt,
            needsRepair: false,
            entries: kept,
            formatVersion: current.formatVersion,
          );
        });
        if (result == ManifestWriteResult.conflictExceeded) {
          await _markNeedsRepair();
        }
      } catch (error) {
        debugPrint('[gallery] 缩略图清单写回失败: $error');
      }
    }
    return updated.length;
  }

  /// 补齐单条（含网络瞬断重试）：本机到 OSS 的直连链路偶发 SSL
  /// 握手超时，仅对该类错误退避重试，其余错误原样抛出由调用方跳过。
  Future<PhotoEntry?> _backfillEntryWithRetry(
    UserSession session,
    PhotoEntry entry,
  ) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await _backfillEntry(session, entry);
      } on AppError catch (error) {
        if (attempt >= GalleryConfig.thumbBackfillRetryAttempts ||
            error.code != 'OSS_NETWORKUNAVAILABLE') {
          rethrow;
        }
        await Future<void>.delayed(
          Duration(seconds: 1 << attempt),
        );
      }
    }
  }

  /// 补齐单条：生成缩略图并上传为独立对象，返回更新后的条目；
  /// 生成不了（如超大图缩放失败）返回 null。
  Future<PhotoEntry?> _backfillEntry(
    UserSession session,
    PhotoEntry entry,
  ) async {
    String tempPath;
    if (entry.mediaType == PhotoMediaType.video) {
      final bytes = await _ossClient.downloadVideoSnapshot(entry.key, session);
      final temp = File(
        '${Directory.systemTemp.path}'
        '/thumb-backfill-${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await temp.writeAsBytes(bytes, flush: true);
      tempPath = temp.path;
    } else {
      tempPath = await _resizeOriginalThumbnail(session, entry);
      if (tempPath.isEmpty) return null;
    }
    final thumbKey = thumbKeyFor(session, entry.key);
    try {
      await _ossClient.uploadFile(
        thumbKey,
        tempPath,
        session,
        taskId: 'thumb-${DateTime.now().microsecondsSinceEpoch}',
      );
    } finally {
      final temp = File(tempPath);
      if (await temp.exists()) await temp.delete();
    }
    return PhotoEntry(
      key: entry.key,
      mediaType: entry.mediaType,
      takenAt: entry.takenAt,
      size: entry.size,
      directory: entry.directory,
      thumbKey: thumbKey,
      modifiedMs: entry.modifiedMs,
      width: entry.width,
      height: entry.height,
      latitude: entry.latitude,
      longitude: entry.longitude,
      device: entry.device,
    );
  }

  /// 超大图缩略图补齐的原图处理：下载原图到临时文件，本地缩放为
  /// JPEG 后删除原图。失败返回空字符串（调用方跳过该条目）。
  Future<String> _resizeOriginalThumbnail(
    UserSession session,
    PhotoEntry entry,
  ) async {
    final original = File(
      '${Directory.systemTemp.path}'
      '/thumb-backfill-original-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await _ossClient.downloadToFile(
        entry.key,
        session,
        original,
        taskId: 'thumb-backfill-${DateTime.now().microsecondsSinceEpoch}',
        onProgress: (_, __) {},
        isCanceled: () => false,
      );
      final bytes = await _mediaBridge.resizeImage(original.path);
      if (bytes == null) return '';
      final thumb = File(
        '${Directory.systemTemp.path}'
        '/thumb-backfill-${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await thumb.writeAsBytes(bytes, flush: true);
      return thumb.path;
    } finally {
      if (await original.exists()) await original.delete();
    }
  }

  /// 媒体删除后的索引增量清理：移除清单条目与本地副本，删除视频
  /// 缩略图对象（失败不阻塞）。[deletedKeys] 为已删除的对象 key。
  Future<void> removeDeletedMedia(
    UserSession session,
    Iterable<String> deletedKeys,
  ) async {
    final mediaKeys = deletedKeys.where(isMediaKey).toSet();
    if (mediaKeys.isEmpty) return;
    await _database.removeEntries(mediaKeys);

    for (final key in mediaKeys) {
      try {
        await _ossClient.delete(thumbKeyFor(session, key), session);
      } catch (error) {
        // 残留缩略图对象无害，不阻塞删除流程。
        debugPrint('[gallery] 缩略图对象删除失败（容忍）: $error');
      }
    }

    try {
      final result = await updateManifest(session, (current) {
        final kept = current.entries
            .where((candidate) => !mediaKeys.contains(candidate.key))
            .toList();
        return PhotoManifest(
          version: current.version,
          scannedAt: current.scannedAt,
          needsRepair: false,
          entries: kept,
          formatVersion: current.formatVersion,
        );
      });
      if (result == ManifestWriteResult.conflictExceeded) {
        await _markNeedsRepair();
      }
    } catch (error) {
      debugPrint('[gallery] 删除索引清理失败: $error');
    }
  }

  /// 回收站还原后重新纳入索引（读取对象元数据与 EXIF）。
  Future<void> restoreMedia(
    UserSession session,
    Iterable<String> restoredKeys,
  ) async {
    final mediaKeys = restoredKeys.where(isMediaKey).toList();
    if (mediaKeys.isEmpty) return;
    for (final key in mediaKeys) {
      try {
        final objects = await _ossClient.listAllObjects(key, session);
        final object = objects.firstWhere(
          (candidate) => candidate.key == key,
          orElse: () => throw AppError('对象不存在'),
        );
        final entry = await _scanEntry(session, object);
        if (entry != null) {
          await _database.upsertEntries(<PhotoEntry>[entry]);
        }
      } catch (error) {
        debugPrint('[gallery] 还原对象索引失败: $error');
      }
    }
    try {
      final localEntries = await _database.readAllEntries();
      final result = await updateManifest(session, (current) {
        final merged = <String, PhotoEntry>{
          for (final entry in current.entries) entry.key: entry,
          for (final entry in localEntries) entry.key: entry,
        };
        final kept = merged.values.toList()
          ..sort((left, right) => right.takenAt.compareTo(left.takenAt));
        return PhotoManifest(
          version: current.version,
          scannedAt: current.scannedAt,
          needsRepair: false,
          entries: kept,
          formatVersion: current.formatVersion,
        );
      });
      if (result == ManifestWriteResult.conflictExceeded) {
        await _markNeedsRepair();
      }
    } catch (error) {
      debugPrint('[gallery] 还原索引合并失败: $error');
    }
  }

  bool isMediaKey(String key) {
    final name = key.substring(key.lastIndexOf('/') + 1);
    return isMediaFileName(name);
  }

  Future<void> _markNeedsRepair() async {
    final meta = await _database.readIndexMeta();
    await _database.writeIndexMeta(PhotoIndexMeta(
      version: meta?.version ?? 0,
      scannedAt: meta?.scannedAt,
      needsRepair: true,
    ));
  }

  static String? _deviceName() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isMacOS) return 'macOS';
    return null;
  }
}
