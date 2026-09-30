import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:private_domain_oss/private_domain_oss.dart';

import '../../../core/errors/app_error.dart';
import '../../auth/domain/user_session.dart';
import '../../workspace/infrastructure/oss_client.dart';
import '../domain/gallery_config.dart';
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
    final bytes = await _ossClient.download(key, session);
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
    final manifestKey = '$root${GalleryConfig.manifestRelativeKey}';
    final thumbPrefix = '$root${GalleryConfig.thumbRelativePrefix}';
    final trashPrefix = '$root.trash/';

    final objects = await _ossClient.listAllObjects(root, session);
    final mediaObjects = <OssNativeObject>[];
    for (final object in objects) {
      final key = object.key;
      if (key.endsWith('/')) continue;
      if (key == manifestKey || key.startsWith(thumbPrefix)) continue;
      if (key.startsWith(trashPrefix)) continue;
      final name = key.substring(key.lastIndexOf('/') + 1);
      if (!isMediaFileName(name)) continue;
      mediaObjects.add(object);
    }
    onProgress?.call(0, mediaObjects.length);

    final entries = <PhotoEntry>[];
    for (var start = 0;
        start < mediaObjects.length;
        start += GalleryConfig.scanExifConcurrency) {
      final chunk = mediaObjects.sublist(
        start,
        min(start + GalleryConfig.scanExifConcurrency, mediaObjects.length),
      );
      final parsed = await Future.wait(chunk.map(
        (object) => _scanEntry(session, object),
      ));
      for (final entry in parsed) {
        if (entry != null) entries.add(entry);
      }
      onProgress?.call(min(start + chunk.length, mediaObjects.length),
          mediaObjects.length);
    }
    entries.sort((left, right) => right.takenAt.compareTo(left.takenAt));

    final manifest = PhotoManifest(
      version: 0,
      scannedAt: DateTime.now(),
      needsRepair: false,
      entries: entries,
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
    );
  }

  Future<PhotoEntry?> _scanEntry(
    UserSession session,
    OssNativeObject object,
  ) async {
    final key = object.key;
    final directory = key.substring(0, key.lastIndexOf('/') + 1);
    final name = key.substring(key.lastIndexOf('/') + 1);
    final mediaType = mediaTypeOf(name);
    final modified = object.lastModifiedMilliseconds;
    final fileTime = modified == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true).toLocal();
    try {
      if (mediaType == PhotoMediaType.image) {
        final exif = await _ossClient.readImageExif(key, session);
        return PhotoEntry(
          key: key,
          mediaType: mediaType,
          takenAt: exif.takenAt ?? fileTime,
          size: object.size,
          directory: directory,
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
        takenAt: fileTime,
        size: object.size,
        directory: directory,
        modifiedMs: modified,
      );
    } catch (error) {
      debugPrint('[gallery] 扫描对象 $key 失败: $error');
      return null;
    }
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
    if (mediaType == PhotoMediaType.video && thumbLocalPath != null) {
      try {
        thumbKey = thumbKeyFor(session, objectPath);
        await _ossClient.uploadFile(
          thumbKey,
          thumbLocalPath,
          session,
          taskId: 'thumb-${DateTime.now().microsecondsSinceEpoch}',
        );
      } catch (error) {
        debugPrint('[gallery] 视频缩略图上传失败（不阻塞）: $error');
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
        takenAt = exif.takenAt ?? fileTime;
        width = exif.width;
        height = exif.height;
        latitude = exif.latitude;
        longitude = exif.longitude;
      } catch (_) {
        takenAt = fileTime;
      }
    } else {
      try {
        takenAt = await _mediaBridge.readVideoTakenAt(localPath) ?? fileTime;
      } catch (_) {
        takenAt = fileTime;
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
      if (!isVideoKey(key)) continue;
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

  bool isVideoKey(String key) {
    final name = key.substring(key.lastIndexOf('/') + 1);
    return isVideoFileName(name);
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
