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
import 'photo_index_repository.dart';

/// 清单读-改-写回调：由 [PhotoIndexRepository] 提供，扫描结果经它
/// 写回 OSS 清单对象，保持原调用链不变。
typedef ManifestUpdater = Future<ManifestWriteResult> Function(
  UserSession session,
  PhotoManifest Function(PhotoManifest manifest) mutate,
);

/// 清单变更投递回调：扫描/回填产生的增量条目走仓库的合并写入队列。
typedef ManifestChangeEnqueuer = void Function(
  UserSession session, {
  Iterable<PhotoEntry> upserts,
  Iterable<String> deletes,
});

/// 照片扫描协作类：承载全量扫描建索引与存量缩略图补齐，由
/// [PhotoIndexRepository] 持有；清单读写与增量记账仍由仓库负责。
class PhotoScanner {
  PhotoScanner({
    required OssClient ossClient,
    required GalleryDatabase database,
    required ManifestUpdater updateManifest,
    required ManifestChangeEnqueuer enqueueManifestChange,
    MediaBridge? mediaBridge,
    Duration thumbBackfillEntryTimeout = GalleryConfig.thumbBackfillEntryTimeout,
    Duration thumbBackfillRetryBaseDelay = const Duration(seconds: 1),
  })  : _ossClient = ossClient,
        _database = database,
        _updateManifest = updateManifest,
        _enqueueManifestChange = enqueueManifestChange,
        _mediaBridge = mediaBridge ?? MediaBridge(),
        _thumbBackfillEntryTimeout = thumbBackfillEntryTimeout,
        _thumbBackfillRetryBaseDelay = thumbBackfillRetryBaseDelay;

  final OssClient _ossClient;
  final GalleryDatabase _database;
  final ManifestUpdater _updateManifest;
  final ManifestChangeEnqueuer _enqueueManifestChange;
  final MediaBridge _mediaBridge;
  final Duration _thumbBackfillEntryTimeout;
  final Duration _thumbBackfillRetryBaseDelay;

  String thumbKeyFor(UserSession session, String objectKey) =>
      '${session.rootPrefix}${GalleryConfig.thumbRelativePrefix}'
      '$objectKey.jpg';

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
            reused ? cached : await scanEntry(session, object, cached: cached);
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
      final result = await _updateManifest(session, (current) {
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
  /// 已有缩略图映射，避免重复截帧上传。全量扫描与还原流程共用。
  Future<PhotoEntry?> scanEntry(
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
      _enqueueManifestChange(session, upserts: updated);
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
}
