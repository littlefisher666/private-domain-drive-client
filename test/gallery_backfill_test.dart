import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/core/errors/app_error.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/gallery/domain/photo_entry.dart';
import 'package:private_domain_drive_client/features/gallery/infrastructure/gallery_database.dart';
import 'package:private_domain_drive_client/features/gallery/infrastructure/photo_index_repository.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_oss/private_domain_oss.dart';

/// 截帧/上传行为可编排的假 OSS 客户端。
class _FakeBackfillOss extends OssClient {
  /// 每个对象 key 的截帧行为：true 表示挂起不返回，否则返回一帧字节。
  final Set<String> hangKeys;
  final Map<String, int> networkFailuresBeforeSuccess = <String, int>{};
  final Set<String> persistentlyFailingKeys = <String>{};

  final List<String> uploadedThumbKeys = <String>[];
  final List<String> snapshotKeys = <String>[];
  final Map<String, String?> manifestContents = <String, String?>{};

  _FakeBackfillOss({this.hangKeys = const <String>{}});

  AppError _networkError() =>
      AppError('网络连接不可用', code: 'OSS_NETWORKUNAVAILABLE');

  @override
  Future<List<int>> downloadVideoSnapshot(
    String path,
    UserSession session,
  ) async {
    snapshotKeys.add(path);
    final remaining = networkFailuresBeforeSuccess[path];
    if (remaining != null && remaining > 0) {
      networkFailuresBeforeSuccess[path] = remaining - 1;
      throw _networkError();
    }
    if (persistentlyFailingKeys.contains(path)) {
      throw _networkError();
    }
    if (hangKeys.contains(path)) {
      // 模拟挂起：永不完成。
      await Completer<void>().future;
    }
    return <int>[1, 2, 3, 4];
  }

  @override
  Future<void> uploadFile(
    String path,
    String localPath,
    UserSession session, {
    required String taskId,
    void Function(int transferredBytes, int totalBytes)? onProgress,
  }) async {
    uploadedThumbKeys.add(path);
  }

  @override
  Future<List<OssNativeObject>> listAllObjects(
    String path,
    UserSession session,
  ) async {
    final raw = manifestContents[path];
    if (raw == null) return const <OssNativeObject>[];
    return <OssNativeObject>[
      OssNativeObject(key: path, size: raw.length, etag: 'e1'),
    ];
  }

  @override
  Future<List<int>> download(
    String path,
    UserSession session, {
    int? maxBytes,
  }) async {
    final raw = manifestContents[path];
    if (raw == null) throw StateError('对象不存在');
    return raw.codeUnits;
  }

  @override
  Future<void> uploadText(
    String path,
    String content,
    UserSession session,
  ) async {
    manifestContents[path] = content;
  }
}

/// 内存版元数据库：不落盘、不依赖 sqflite 平台插件，
/// 任何能跑 Dart 测试的环境（含 Linux）均可执行。
class _InMemoryGalleryDatabase extends GalleryDatabase {
  final List<PhotoEntry> _entries = <PhotoEntry>[];
  PhotoIndexMeta? _meta;

  @override
  Future<PhotoIndexMeta?> readIndexMeta() async => _meta;

  @override
  Future<void> writeIndexMeta(PhotoIndexMeta meta) async {
    _meta = meta;
  }

  @override
  Future<List<PhotoEntry>> readAllEntries() async {
    final sorted = List<PhotoEntry>.of(_entries)
      ..sort((a, b) => b.takenAt.compareTo(a.takenAt));
    return sorted;
  }

  @override
  Future<void> upsertEntries(Iterable<PhotoEntry> entries) async {
    for (final entry in entries) {
      _entries.removeWhere((existing) => existing.key == entry.key);
      _entries.add(entry);
    }
  }

  @override
  Future<void> removeEntries(Iterable<String> keys) async {
    _entries.removeWhere((entry) => keys.contains(entry.key));
  }

  @override
  Future<void> replaceEntries(Iterable<PhotoEntry> entries) async {
    _entries
      ..clear()
      ..addAll(entries);
  }
}

UserSession _session() {
  return const UserSession(
    userId: 'u1',
    account: 'u1',
    displayName: '测试用户',
    role: 'member',
    capabilities: Capabilities.member(),
    rootPrefix: 'shared/',
  );
}

PhotoEntry _videoEntry(String key) {
  return PhotoEntry(
    key: key,
    mediaType: PhotoMediaType.video,
    takenAt: DateTime(2026, 10, 5, 18),
    size: 1024,
    directory: 'shared/家庭资料/相册/',
    thumbKey: null,
  );
}

PhotoIndexRepository _repository(
  _FakeBackfillOss oss,
  _InMemoryGalleryDatabase database, {
  Duration timeout = const Duration(milliseconds: 200),
}) {
  return PhotoIndexRepository(
    ossClient: oss,
    database: database,
    thumbBackfillEntryTimeout: timeout,
    thumbBackfillRetryBaseDelay: const Duration(milliseconds: 1),
  );
}

void main() {
  test('挂起的截帧请求超时后不堵死队列，其余条目正常补齐', () async {
    final oss = _FakeBackfillOss(hangKeys: <String>{'shared/v-hang.mp4'});
    final database = _InMemoryGalleryDatabase();
    await database.upsertEntries(<PhotoEntry>[
      _videoEntry('shared/v-hang.mp4'),
      _videoEntry('shared/v-ok1.mp4'),
      _videoEntry('shared/v-ok2.mp4'),
    ]);
    final repository = _repository(oss, database);

    final count = await repository.backfillMissingThumbnails(_session());

    expect(count, 2);
    expect(oss.uploadedThumbKeys, containsAll(<String>[
      'shared/.gallery/thumbs/shared/v-ok1.mp4.jpg',
      'shared/.gallery/thumbs/shared/v-ok2.mp4.jpg',
    ]));
    expect(oss.uploadedThumbKeys,
        isNot(contains('shared/.gallery/thumbs/shared/v-hang.mp4.jpg')));
    final entries = await database.readAllEntries();
    final hangEntry =
        entries.firstWhere((entry) => entry.key == 'shared/v-hang.mp4');
    expect(hangEntry.thumbKey, isNull);
  });

  test('网络瞬断时退避重试后成功补齐', () async {
    final oss = _FakeBackfillOss()
      ..networkFailuresBeforeSuccess['shared/v-flaky.mp4'] = 2;
    final database = _InMemoryGalleryDatabase();
    await database
        .upsertEntries(<PhotoEntry>[_videoEntry('shared/v-flaky.mp4')]);
    final repository = _repository(oss, database);

    final count = await repository.backfillMissingThumbnails(_session());

    expect(count, 1);
    expect(oss.uploadedThumbKeys,
        contains('shared/.gallery/thumbs/shared/v-flaky.mp4.jpg'));
    final entries = await database.readAllEntries();
    expect(entries.single.thumbKey,
        'shared/.gallery/thumbs/shared/v-flaky.mp4.jpg');
  });

  test('持续网络失败重试上限后跳过，不阻塞其余条目', () async {
    final oss = _FakeBackfillOss()
      ..persistentlyFailingKeys.add('shared/v-dead.mp4');
    final database = _InMemoryGalleryDatabase();
    await database.upsertEntries(<PhotoEntry>[
      _videoEntry('shared/v-dead.mp4'),
      _videoEntry('shared/v-alive.mp4'),
    ]);
    final repository = _repository(oss, database);

    final count = await repository.backfillMissingThumbnails(_session());

    expect(count, 1);
    expect(oss.snapshotKeys, contains('shared/v-dead.mp4'));
    final entries = await database.readAllEntries();
    final deadEntry =
        entries.firstWhere((entry) => entry.key == 'shared/v-dead.mp4');
    expect(deadEntry.thumbKey, isNull);
  });

  test('全部成功时补齐结果写回 OSS 清单且本地条目带缩略图映射', () async {
    final oss = _FakeBackfillOss();
    final database = _InMemoryGalleryDatabase();
    await database.upsertEntries(<PhotoEntry>[
      _videoEntry('shared/v-a.mp4'),
      _videoEntry('shared/v-b.mp4'),
    ]);
    final repository = _repository(oss, database);

    final count = await repository.backfillMissingThumbnails(_session());

    expect(count, 2);
    final manifestKey =
        repository.manifestKey(_session());
    final raw = oss.manifestContents[manifestKey];
    expect(raw, isNotNull);
    final entries = await database.readAllEntries();
    for (final entry in entries) {
      expect(entry.thumbKey,
          'shared/.gallery/thumbs/${entry.key}.jpg');
      expect(raw, contains(entry.thumbKey!));
    }
  });
}
