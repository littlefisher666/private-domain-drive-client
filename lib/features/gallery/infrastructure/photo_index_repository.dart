import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/errors/app_error.dart';
import '../../auth/domain/user_session.dart';
import '../../workspace/infrastructure/oss_client.dart';
import '../domain/gallery_config.dart';
import '../domain/photo_date_hints.dart';
import '../domain/photo_entry.dart';
import '../domain/photo_manifest.dart';
import 'gallery_database.dart';
import 'media_bridge.dart';
import 'photo_scanner.dart';

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

/// 清单写入结果：成功（携带实际写回的清单版本），或冲突超限需要
/// 标记待修复。
sealed class ManifestWriteResult {
  const ManifestWriteResult();
}

class ManifestWriteSuccess extends ManifestWriteResult {
  const ManifestWriteSuccess(this.version);

  /// 实际写回的清单版本，调用方用它保持本地 meta 版本一致。
  final int version;
}

class ManifestWriteConflictExceeded extends ManifestWriteResult {
  const ManifestWriteConflictExceeded();
}

/// 一次清单变更意图：条目新增/替换与 key 移除集合。
/// 应用顺序为先删后增，同 key 时以 upsert 为准。
class _ManifestChange {
  _ManifestChange({
    required this.session,
    required this.upserts,
    required this.deletes,
  });

  final UserSession session;
  final List<PhotoEntry> upserts;
  final Set<String> deletes;
}

/// 照片索引仓库：OSS 清单对象（读-改-写 + ETag 乐观并发）
/// 与本地 SQLite 副本之间的同步。
class PhotoIndexRepository {
  PhotoIndexRepository({
    required OssClient ossClient,
    required GalleryDatabase database,
    MediaBridge? mediaBridge,
    Duration thumbBackfillEntryTimeout = GalleryConfig.thumbBackfillEntryTimeout,
    Duration thumbBackfillRetryBaseDelay = const Duration(seconds: 1),
  })  : _ossClient = ossClient,
        _database = database,
        _mediaBridge = mediaBridge ?? MediaBridge() {
    // 扫描/缩略图回填域由协作类承载；清单写回与增量记账经回调
    // 回到仓库原调用链，公开 API 与调用时机不变。
    _scanner = PhotoScanner(
      ossClient: ossClient,
      database: database,
      updateManifest: updateManifest,
      enqueueManifestChange: enqueueManifestChange,
      mediaBridge: _mediaBridge,
      thumbBackfillEntryTimeout: thumbBackfillEntryTimeout,
      thumbBackfillRetryBaseDelay: thumbBackfillRetryBaseDelay,
    );
  }

  final OssClient _ossClient;
  final GalleryDatabase _database;
  final MediaBridge _mediaBridge;
  late final PhotoScanner _scanner;

  /// 清单变更意图积压与单飞行写：同一时刻最多一次 RMW 在途，
  /// 一次 RMW 合并应用全部积压意图，写完复查积压继续下一轮。
  final List<_ManifestChange> _pendingManifestChanges = <_ManifestChange>[];
  Future<void>? _manifestWriteInFlight;

  String manifestKey(UserSession session) =>
      '${session.rootPrefix}${GalleryConfig.manifestRelativeKey}';

  String thumbKeyFor(UserSession session, String objectKey) =>
      _scanner.thumbKeyFor(session, objectKey);

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
  /// ETag 变化说明有并发写入，退避后重试，超限返回
  /// [ManifestWriteConflictExceeded]。成功返回写回后的清单版本。
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
      } on FormatException catch (error) {
        debugPrint('[gallery] 清单读取解析失败: $error');
        return const ManifestWriteConflictExceeded();
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
          debugPrint('[gallery] 清单写回 ETag 复查变化，重试($attempt)：'
              '$currentEtag -> ${latest.$2}');
          continue;
        }
      } on FormatException catch (error) {
        debugPrint('[gallery] 清单复查解析失败: $error');
        return const ManifestWriteConflictExceeded();
      } catch (_) {
        // 复查失败时按原计划写入；极端冲突由全量扫描兜底。
      }
      await _ossClient.uploadText(manifestKey(session), next.encode(), session);
      return ManifestWriteSuccess(next.version);
    }
    return const ManifestWriteConflictExceeded();
  }

  /// 投递清单变更意图，由合并队列以单飞行串行方式读-改-写。
  /// 批量上传等密集增量被收敛为「在途聚合 + 尾部一次」的少量 RMW。
  void enqueueManifestChange(
    UserSession session, {
    Iterable<PhotoEntry> upserts = const <PhotoEntry>[],
    Iterable<String> deletes = const <String>[],
  }) {
    _pendingManifestChanges.add(_ManifestChange(
      session: session,
      upserts: List<PhotoEntry>.of(upserts),
      deletes: Set<String>.of(deletes),
    ));
    unawaited(_flushManifestChanges());
  }

  /// 等待在途合并清单写完成并排空当前积压（测试与退出清理用）。
  Future<void> flushPendingManifestWrites() async {
    while (_manifestWriteInFlight != null) {
      await _manifestWriteInFlight;
    }
  }

  Future<void> _flushManifestChanges() async {
    if (_manifestWriteInFlight != null) return;
    final inFlight = _runManifestFlush();
    _manifestWriteInFlight = inFlight;
    try {
      await inFlight;
    } finally {
      _manifestWriteInFlight = null;
      // 积压可能在循环退出与复位之间到达，兜底再踢一轮。
      if (_pendingManifestChanges.isNotEmpty) {
        unawaited(_flushManifestChanges());
      }
    }
  }

  Future<void> _runManifestFlush() async {
    while (_pendingManifestChanges.isNotEmpty) {
      final batch = List<_ManifestChange>.of(_pendingManifestChanges);
      _pendingManifestChanges.clear();
      final session = batch.first.session;
      final upserts = <String, PhotoEntry>{};
      final deletes = <String>{};
      for (final change in batch) {
        deletes.addAll(change.deletes);
        for (final entry in change.upserts) {
          upserts[entry.key] = entry;
          deletes.remove(entry.key);
        }
      }
      try {
        final result = await updateManifest(session, (current) {
          final byKey = <String, PhotoEntry>{
            for (final entry in current.entries) entry.key: entry,
          };
          for (final key in deletes) {
            byKey.remove(key);
          }
          for (final entry in upserts.values) {
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
        if (result is ManifestWriteConflictExceeded) {
          await _markNeedsRepair();
        }
      } catch (error) {
        debugPrint('[gallery] 合并清单写入失败: $error');
      }
    }
  }

  /// 全量扫描建索引：递归列举全部对象、过滤媒体类型、解析拍摄时间，
  /// 写入本地副本并同步生成 OSS 清单对象。具体实现见 [PhotoScanner]。
  Future<PhotoManifest> fullScan(
    UserSession session, {
    void Function(int processed, int total)? onProgress,
    Set<String> pendingUpsertKeys = const <String>{},
    Set<String> pendingDeleteKeys = const <String>{},
  }) {
    return _scanner.fullScan(
      session,
      onProgress: onProgress,
      pendingUpsertKeys: pendingUpsertKeys,
      pendingDeleteKeys: pendingDeleteKeys,
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
    // 远端清单写走合并队列：本地副本已即时更新，RMW 不阻塞调用方。
    enqueueManifestChange(session, upserts: <PhotoEntry>[entry]);
    return entry;
  }

  /// 存量缩略图补齐：为无缩略图映射的视频请求 OSS 服务端截帧；为
  /// 超过 OSS 图片处理大小限制的图片下载原图、本地缩放后上传。
  /// 具体实现见 [PhotoScanner]。
  Future<int> backfillMissingThumbnails(
    UserSession session, {
    void Function(PhotoEntry entry)? onEntryUpdated,
  }) {
    return _scanner.backfillMissingThumbnails(
      session,
      onEntryUpdated: onEntryUpdated,
    );
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

    enqueueManifestChange(session, deletes: mediaKeys);
  }

  /// 回收站还原后重新纳入索引（读取对象元数据与 EXIF）。
  Future<void> restoreMedia(
    UserSession session,
    Iterable<String> restoredKeys,
  ) async {
    final mediaKeys = restoredKeys.where(isMediaKey).toList();
    if (mediaKeys.isEmpty) return;
    final scanned = <PhotoEntry>[];
    for (final key in mediaKeys) {
      try {
        final objects = await _ossClient.listAllObjects(key, session);
        final object = objects.firstWhere(
          (candidate) => candidate.key == key,
          orElse: () => throw AppError('对象不存在'),
        );
        final entry = await _scanner.scanEntry(session, object);
        if (entry != null) {
          await _database.upsertEntries(<PhotoEntry>[entry]);
          scanned.add(entry);
        }
      } catch (error) {
        debugPrint('[gallery] 还原对象索引失败: $error');
      }
    }
    if (scanned.isNotEmpty) {
      enqueueManifestChange(session, upserts: scanned);
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
