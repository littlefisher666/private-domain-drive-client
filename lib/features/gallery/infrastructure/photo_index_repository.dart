import 'dart:async';
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
        _mediaBridge = mediaBridge ?? MediaBridge(),
        _thumbBackfillEntryTimeout = thumbBackfillEntryTimeout,
        _thumbBackfillRetryBaseDelay = thumbBackfillRetryBaseDelay;

  final OssClient _ossClient;
  final GalleryDatabase _database;
  final MediaBridge _mediaBridge;
  final Duration _thumbBackfillEntryTimeout;
  final Duration _thumbBackfillRetryBaseDelay;

  /// 清单变更意图积压与单飞行写：同一时刻最多一次 RMW 在途，
  /// 一次 RMW 合并应用全部积压意图，写完复查积压继续下一轮。
  final List<_ManifestChange> _pendingManifestChanges = <_ManifestChange>[];
  Future<void>? _manifestWriteInFlight;

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
  /// 写入本地副本并同步生成 OSS 清单对象。[pendingUpsertKeys] /
  /// [pendingDeleteKeys] 为扫描期间发生的增量记账（上传/还原、删除），
  /// 写回时合并进结果，避免整体覆盖造成条目丢失或复活。扫描结果与
  /// 清单写入失败不抛出异常，由调用方根据返回的标记决定提示策略。
  Future<PhotoManifest> fullScan(
    UserSession session, {
    void Function(int processed, int total)? onProgress,
    Set<String> pendingUpsertKeys = const <String>{},
    Set<String> pendingDeleteKeys = const <String>{},
  }) async {
    final root = session.rootPrefix;
    final galleryPrefix = '$root.gallery/';
    final trashPrefix = '$root.trash/';
    final movesPrefix = '$root.moves/';

    final objects = await _ossClient.listAllObjects(root, session);
    final mediaObjects = <OssNativeObject>[];
    for (final object in objects) {
      final key = object.key;
      if (key.endsWith('/')) continue;
      if (key.startsWith(galleryPrefix)) continue;
      if (key.startsWith(trashPrefix)) continue;
      if (key.startsWith(movesPrefix)) continue;
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

    // 合并扫描期间增量：剔除已删除 key（先删后传时以 upsert 为准），
    // 并入扫描期间写入本地副本的上传/还原条目。
    final effectiveDeletes =
        pendingDeleteKeys.difference(pendingUpsertKeys);
    final merged = <String, PhotoEntry>{
      for (final entry in entries) entry.key: entry,
    };
    for (final key in effectiveDeletes) {
      merged.remove(key);
    }
    if (pendingUpsertKeys.isNotEmpty) {
      final localEntries = await _database.readAllEntries();
      for (final entry in localEntries) {
        if (pendingUpsertKeys.contains(entry.key)) {
          merged[entry.key] = entry;
        }
      }
    }
    final mergedEntries = merged.values.toList()
      ..sort((left, right) => right.takenAt.compareTo(left.takenAt));

    final manifest = PhotoManifest(
      version: 0,
      scannedAt: DateTime.now(),
      needsRepair: false,
      entries: mergedEntries,
      formatVersion: PhotoManifest.currentFormatVersion,
    );
    await _database.replaceEntries(mergedEntries);
    // 先写占位 meta 保留断点续扫成果；清单写回成功后以实际版本覆盖，
    // 避免「本地版本恒 0 → 下次进相册页必然全量清单替换」。
    await _database.writeIndexMeta(PhotoIndexMeta(
      version: manifest.version,
      scannedAt: manifest.scannedAt,
      needsRepair: false,
    ));

    // 清单写入失败不影响本地副本；下次进入相册页会再次尝试同步。
    try {
      final result = await updateManifest(session, (current) {
        final byKey = <String, PhotoEntry>{
          for (final entry in mergedEntries) entry.key: entry,
        };
        // 兜底合并：写回瞬间远端清单中已有、但本机合并结果不含的条目
        //（如其他设备扫描期间写入）；本机已删除的 key 不并入。
        for (final candidate in current.entries) {
          if (!byKey.containsKey(candidate.key) &&
              !effectiveDeletes.contains(candidate.key)) {
            byKey[candidate.key] = candidate;
          }
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
      switch (result) {
        case ManifestWriteSuccess(:final version):
          debugPrint('[gallery] 扫描清单写回成功: version=$version');
          await _database.writeIndexMeta(PhotoIndexMeta(
            version: version,
            scannedAt: manifest.scannedAt,
            needsRepair: false,
          ));
        case ManifestWriteConflictExceeded():
          debugPrint('[gallery] 扫描清单写回冲突超限，标记待修复');
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
      version: finalMeta?.version ?? manifest.version,
      scannedAt: manifest.scannedAt,
      needsRepair: finalMeta?.needsRepair ?? false,
      entries: mergedEntries,
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
    // 远端清单写走合并队列：本地副本已即时更新，RMW 不阻塞调用方。
    enqueueManifestChange(session, upserts: <PhotoEntry>[entry]);
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
              .timeout(_thumbBackfillEntryTimeout,
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
      enqueueManifestChange(session, upserts: updated);
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
          _thumbBackfillRetryBaseDelay * (1 << attempt),
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
        final entry = await _scanEntry(session, object);
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
