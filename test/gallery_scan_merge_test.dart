import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/gallery/application/gallery_controller.dart';
import 'package:private_domain_drive_client/features/gallery/domain/photo_entry.dart';
import 'package:private_domain_drive_client/features/gallery/domain/photo_manifest.dart';
import 'package:private_domain_drive_client/features/gallery/infrastructure/gallery_database.dart';
import 'package:private_domain_drive_client/features/gallery/infrastructure/photo_index_repository.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/shared/state/app_services.dart';
import 'package:private_domain_oss/private_domain_oss.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _manifestKey = 'shared/.gallery/index/photos.json';

/// 全量扫描假 OSS：媒体对象列举 + 清单 RMW，EXIF 读取可被 gate 挂起
/// 以模拟「扫描进行中」的窗口。
class _ScanFakeOss extends OssClient {
  _ScanFakeOss({required this.mediaObjects, this.exifGate});

  final List<OssNativeObject> mediaObjects;
  final Completer<void>? exifGate;
  String manifestContent = PhotoManifest(
    version: 0,
    scannedAt: null,
    needsRepair: false,
    entries: const <PhotoEntry>[],
  ).encode();
  String _etag = 'e0';
  final List<String> uploads = <String>[];

  void seedRemoteManifest(PhotoManifest manifest) {
    manifestContent = manifest.encode();
    _etag = 'seed';
  }

  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<List<OssNativeObject>> listAllObjects(
    String path,
    UserSession session,
  ) async {
    if (path == _manifestKey) {
      return <OssNativeObject>[
        OssNativeObject(key: path, size: manifestContent.length, etag: _etag),
      ];
    }
    return <OssNativeObject>[
      ...mediaObjects,
      OssNativeObject(
        key: _manifestKey,
        size: manifestContent.length,
        etag: _etag,
      ),
    ];
  }

  @override
  Future<List<int>> download(
    String path,
    UserSession session, {
    int? maxBytes,
  }) async {
    if (path != _manifestKey) throw StateError('意外的下载: $path');
    return utf8.encode(manifestContent);
  }

  @override
  Future<ImageExifInfo> readImageExif(String path, UserSession session) async {
    final gate = exifGate;
    if (gate != null) await gate.future;
    return const ImageExifInfo(takenAt: null, width: 100, height: 80);
  }

  @override
  Future<ImageExifInfo> readLocalImageExif(File file) async {
    return const ImageExifInfo(takenAt: null, width: 100, height: 80);
  }

  @override
  Future<void> uploadText(
    String path,
    String content,
    UserSession session,
  ) async {
    if (path != _manifestKey) throw StateError('意外的上传: $path');
    uploads.add(content);
    manifestContent = content;
    _etag = 'e${uploads.length}';
  }

  @override
  Future<void> delete(String path, UserSession session) async {}
}

UserSession _session() {
  return const UserSession(
    userId: 'u1',
    account: 'u1',
    displayName: '测试用户',
    role: 'member',
    capabilities: Capabilities.member(),
    rootPrefix: 'shared/',
    ossConfig: OssConfig(
      bucket: 'bucket',
      region: 'cn-test',
      endpoint: 'oss-cn-test.aliyuncs.com',
      rootPrefix: 'shared/',
    ),
    credentials: OssCredentials(accessKeyId: 'ak', accessKeySecret: 'sk'),
  );
}

class _FakeSessionRepository implements SessionRepository {
  _FakeSessionRepository(this.session);

  final UserSession? session;

  @override
  Future<UserSession?> restore() async => session;

  @override
  Future<UserSession> login({
    required String account,
    required String password,
  }) async =>
      session!;

  @override
  Future<UserSession> changePassword({
    required UserSession session,
    required String currentPassword,
    required String newPassword,
  }) async =>
      session;

  @override
  Future<void> logout() async {}
}

OssNativeObject _mediaObject(String key) {
  return OssNativeObject(
    key: key,
    size: 2048,
    lastModifiedMilliseconds: DateTime(2026, 5, 1).millisecondsSinceEpoch,
  );
}

/// 内存版索引数据库。
class _MemoryDatabase extends GalleryDatabase {
  final Map<String, PhotoEntry> entries = <String, PhotoEntry>{};
  PhotoIndexMeta? meta;
  int replaceCalls = 0;

  @override
  Future<List<PhotoEntry>> readAllEntries() async => entries.values.toList();

  @override
  Future<void> upsertEntries(Iterable<PhotoEntry> upserts) async {
    for (final entry in upserts) {
      entries[entry.key] = entry;
    }
  }

  @override
  Future<void> removeEntries(Iterable<String> keys) async {
    for (final key in keys) {
      entries.remove(key);
    }
  }

  @override
  Future<void> replaceEntries(Iterable<PhotoEntry> replaced) async {
    replaceCalls++;
    entries
      ..clear()
      ..addEntries([for (final entry in replaced) MapEntry(entry.key, entry)]);
  }

  @override
  Future<PhotoIndexMeta?> readIndexMeta() async => meta;

  @override
  Future<void> writeIndexMeta(PhotoIndexMeta next) async => meta = next;
}

Future<void> _waitFor(
  Future<bool> Function() predicate, {
  String? because,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('等待条件超时${because == null ? '' : '：$because'}');
}

Future<File> _tempImage(String name) async {
  final file = File(
    '${Directory.systemTemp.path}'
    '/scan-merge-${DateTime.now().microsecondsSinceEpoch}-$name',
  );
  await file.writeAsBytes(<int>[1, 2, 3], flush: true);
  return file;
}

void main() {
  final tempFiles = <File>[];
  Future<File> trackedTempImage(String name) async {
    final file = await _tempImage(name);
    tempFiles.add(file);
    return file;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    for (final file in tempFiles) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
    tempFiles.clear();
  });

  group('PhotoIndexRepository.fullScan 写回合并', () {
    test('扫描期间上传的照片不丢失、删除的照片不复活', () async {
      final gate = Completer<void>();
      final oss = _ScanFakeOss(
        mediaObjects: <OssNativeObject>[
          _mediaObject('shared/相册/old.jpg'),
          _mediaObject('shared/相册/keep.jpg'),
        ],
        exifGate: gate,
      );
      final database = _MemoryDatabase();
      final repository = PhotoIndexRepository(
        ossClient: oss,
        database: database,
      );
      final session = _session();
      final upserts = <String>{};
      final deletes = <String>{};

      final scanFuture = repository.fullScan(
        session,
        pendingUpsertKeys: upserts,
        pendingDeleteKeys: deletes,
      );

      // 扫描进行中：上传一张照片、删除一张扫描已列举的照片。
      upserts.add('shared/相册/new.jpg');
      deletes.add('shared/相册/old.jpg');
      final newFile = await trackedTempImage('new.jpg');
      await repository.addUploadedMedia(
        session,
        objectPath: 'shared/相册/new.jpg',
        localPath: newFile.path,
      );
      // 先排空增量合并队列，避免与扫描写回产生无谓的 ETag 冲突。
      await repository.flushPendingManifestWrites();
      gate.complete();

      final manifest = await scanFuture;
      final written = PhotoManifest.decode(oss.uploads.last);
      final keys = written.entries.map((entry) => entry.key).toSet();

      expect(keys, contains('shared/相册/new.jpg'));
      expect(keys, contains('shared/相册/keep.jpg'));
      expect(keys, isNot(contains('shared/相册/old.jpg')));
      expect(database.entries.keys, contains('shared/相册/new.jpg'));
      expect(database.entries.keys, isNot(contains('shared/相册/old.jpg')));
      // 本地 meta 版本与远端清单实际版本一致（不再恒为 0）。
      expect(manifest.version, written.version);
      expect(manifest.version, greaterThan(0));
      expect(database.meta?.version, written.version);
      expect(database.meta?.needsRepair, isFalse);
    });

    test('扫描期间先删后传时以增量 upsert 为准', () async {
      final gate = Completer<void>();
      final oss = _ScanFakeOss(
        mediaObjects: <OssNativeObject>[
          _mediaObject('shared/相册/reup.jpg'),
        ],
        exifGate: gate,
      );
      final repository = PhotoIndexRepository(
        ossClient: oss,
        database: _MemoryDatabase(),
      );
      final session = _session();

      final scanFuture = repository.fullScan(
        session,
        pendingUpsertKeys: <String>{'shared/相册/reup.jpg'},
        pendingDeleteKeys: <String>{'shared/相册/reup.jpg'},
      );

      final reupFile = await trackedTempImage('reup.jpg');
      await repository.addUploadedMedia(
        session,
        objectPath: 'shared/相册/reup.jpg',
        localPath: reupFile.path,
      );
      await repository.flushPendingManifestWrites();
      gate.complete();

      await scanFuture;
      final written = PhotoManifest.decode(oss.uploads.last);
      expect(
        written.entries.map((entry) => entry.key),
        contains('shared/相册/reup.jpg'),
      );
    });

    test('扫描写回兜底并入其他设备写入的远端条目', () async {
      final oss = _ScanFakeOss(
        mediaObjects: <OssNativeObject>[
          _mediaObject('shared/相册/local.jpg'),
        ],
      );
      oss.seedRemoteManifest(PhotoManifest(
        version: 5,
        scannedAt: null,
        needsRepair: false,
        entries: <PhotoEntry>[
          PhotoEntry(
            key: 'shared/相册/other-device.jpg',
            mediaType: PhotoMediaType.image,
            takenAt: DateTime(2026, 4, 1),
            size: 100,
            directory: 'shared/相册/',
          ),
        ],
      ));
      final repository = PhotoIndexRepository(
        ossClient: oss,
        database: _MemoryDatabase(),
      );

      final manifest = await repository.fullScan(_session());

      final written = PhotoManifest.decode(oss.uploads.last);
      final keys = written.entries.map((entry) => entry.key).toSet();
      expect(keys, contains('shared/相册/local.jpg'));
      expect(keys, contains('shared/相册/other-device.jpg'));
      expect(manifest.version, greaterThan(5));
    });
  });

  group('GalleryController 扫描期间增量记账', () {
    test('上传与删除钩子在扫描中记账，写回结果不丢不复活', () async {
      final gate = Completer<void>();
      final oss = _ScanFakeOss(
        mediaObjects: <OssNativeObject>[
          _mediaObject('shared/相册/old.jpg'),
          _mediaObject('shared/相册/keep.jpg'),
        ],
        exifGate: gate,
      );
      final database = _MemoryDatabase();
      final app = AppServices(
        sessionRepository: _FakeSessionRepository(_session()),
        ossClient: oss,
      );
      addTearDown(app.dispose);
      await app.bootstrap();
      final controller = GalleryController(
        services: app,
        ossClient: oss,
        database: database,
      );
      addTearDown(controller.dispose);
      app.setGalleryHooks(controller);

      unawaited(controller.rebuildIndex());
      await _waitFor(
        () async =>
            controller.scanProgressListenable.value != null &&
            controller.scanProgressListenable.value!.$2 > 0,
        because: '全量扫描应已开始并挂起在 EXIF 读取',
      );

      final newFile = await trackedTempImage('ctrl-new.jpg');
      await controller.onMediaUploaded(
        objectPath: 'shared/相册/new.jpg',
        localPath: newFile.path,
      );
      await controller.onObjectsDeleted(<String>{'shared/相册/old.jpg'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      gate.complete();

      await _waitFor(
        () async => controller.phase == GalleryPhase.ready,
        because: '扫描应完成进入 ready',
      );
      await _waitFor(
        () async => oss.uploads.isNotEmpty &&
            PhotoManifest.decode(oss.uploads.last).entries.isNotEmpty,
      );

      final written = PhotoManifest.decode(oss.uploads.last);
      final keys = written.entries.map((entry) => entry.key).toSet();
      expect(keys, contains('shared/相册/new.jpg'));
      expect(keys, contains('shared/相册/keep.jpg'));
      expect(keys, isNot(contains('shared/相册/old.jpg')));
      expect(database.entries.keys, contains('shared/相册/new.jpg'));
      expect(database.entries.keys, isNot(contains('shared/相册/old.jpg')));
    });
  });
}
