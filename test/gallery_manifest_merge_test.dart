import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/gallery/domain/photo_entry.dart';
import 'package:private_domain_drive_client/features/gallery/domain/photo_manifest.dart';
import 'package:private_domain_drive_client/features/gallery/infrastructure/gallery_database.dart';
import 'package:private_domain_drive_client/features/gallery/infrastructure/photo_index_repository.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_oss/private_domain_oss.dart';

/// 可控清单 OSS 假客户端：首次列举被 [gate] 挂起，用于在合并写
/// 在途期间继续投递变更意图。
class _GatedManifestOss extends OssClient {
  _GatedManifestOss(this.gate);

  final Completer<void> gate;
  String content = PhotoManifest(
    version: 5,
    scannedAt: null,
    needsRepair: false,
    entries: const <PhotoEntry>[],
  ).encode();
  final List<String> uploads = <String>[];

  @override
  Future<List<OssNativeObject>> listAllObjects(
    String path,
    UserSession session,
  ) async {
    await gate.future;
    return <OssNativeObject>[
      OssNativeObject(key: path, size: content.length, etag: 'e1'),
    ];
  }

  @override
  Future<List<int>> download(
    String path,
    UserSession session, {
    int? maxBytes,
  }) async {
    return utf8.encode(content);
  }

  @override
  Future<void> uploadText(
    String path,
    String content,
    UserSession session,
  ) async {
    uploads.add(content);
    this.content = content;
  }
}

/// 即时响应的清单 OSS 假客户端：每次写入后更新本地内容与 ETag。
class _ImmediateManifestOss extends OssClient {
  String content = PhotoManifest(
    version: 5,
    scannedAt: null,
    needsRepair: false,
    entries: const <PhotoEntry>[],
  ).encode();
  int writes = 0;
  final List<String> uploads = <String>[];

  @override
  Future<List<OssNativeObject>> listAllObjects(
    String path,
    UserSession session,
  ) async {
    return <OssNativeObject>[
      OssNativeObject(key: path, size: content.length, etag: 'e$writes'),
    ];
  }

  @override
  Future<List<int>> download(
    String path,
    UserSession session, {
    int? maxBytes,
  }) async {
    return utf8.encode(content);
  }

  @override
  Future<void> uploadText(
    String path,
    String content,
    UserSession session,
  ) async {
    uploads.add(content);
    this.content = content;
    writes++;
  }
}

/// 冲突序列假客户端：读取与复查之间 ETag 恒变化，逼出冲突超限。
class _AlwaysConflictOss extends OssClient {
  var reads = 0;

  @override
  Future<List<OssNativeObject>> listAllObjects(
    String path,
    UserSession session,
  ) async {
    final etag = 'e${reads++}';
    return <OssNativeObject>[OssNativeObject(key: path, size: 10, etag: etag)];
  }

  @override
  Future<List<int>> download(
    String path,
    UserSession session, {
    int? maxBytes,
  }) async {
    return utf8.encode(
      PhotoManifest(
        version: 1,
        scannedAt: null,
        needsRepair: false,
        entries: const <PhotoEntry>[],
      ).encode(),
    );
  }

  @override
  Future<void> uploadText(
    String path,
    String content,
    UserSession session,
  ) async {}
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

PhotoEntry _entry(String key, int year) {
  return PhotoEntry(
    key: key,
    mediaType: PhotoMediaType.image,
    takenAt: DateTime(year, 6, 1),
    size: 1024,
    directory: 'shared/相册/',
  );
}

/// 内存版索引数据库：合并写回的本地副作用验证用。
class _MemoryDatabase extends GalleryDatabase {
  final Map<String, PhotoEntry> entries = <String, PhotoEntry>{};
  PhotoIndexMeta? meta;
  int replaceCalls = 0;

  @override
  Future<List<PhotoEntry>> readAllEntries() async =>
      entries.values.toList();

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

void main() {
  test('在途合并写期间的增量聚合到尾部一次写入，而非逐条写', () async {
    final gate = Completer<void>();
    final oss = _GatedManifestOss(gate);
    final repository = PhotoIndexRepository(
      ossClient: oss,
      database: GalleryDatabase(),
    );

    repository.enqueueManifestChange(
      _session(),
      upserts: <PhotoEntry>[_entry('shared/相册/a.jpg', 2026)],
    );
    // 首个 RMW 在途期间继续投递：后续意图应聚合为一次尾部写。
    repository.enqueueManifestChange(
      _session(),
      upserts: <PhotoEntry>[_entry('shared/相册/b.jpg', 2025)],
    );
    repository.enqueueManifestChange(
      _session(),
      deletes: <String>['shared/相册/gone.jpg'],
    );
    expect(oss.uploads, isEmpty, reason: 'RMW 在途时不应产生写入');

    gate.complete();
    await repository.flushPendingManifestWrites();

    // 3 条意图收敛为 2 次写（首个 + 尾部聚合），而非逐条 3 次。
    expect(oss.uploads, hasLength(2));
    final written = PhotoManifest.decode(oss.uploads.last);
    final keys = written.entries.map((entry) => entry.key).toSet();
    expect(keys, containsAll(<String>['shared/相册/a.jpg', 'shared/相册/b.jpg']));
    expect(keys, isNot(contains('shared/相册/gone.jpg')));
  });

  test('串行多轮合并写后清单最终内容包含全部意图', () async {
    final gate = Completer<void>();
    final oss = _GatedManifestOss(gate);
    final repository = PhotoIndexRepository(
      ossClient: oss,
      database: GalleryDatabase(),
    );

    repository.enqueueManifestChange(
      _session(),
      upserts: <PhotoEntry>[_entry('shared/相册/a.jpg', 2026)],
    );
    expect(oss.uploads, isEmpty, reason: 'RMW 在途时不应产生写入');
    gate.complete();
    await repository.flushPendingManifestWrites();

    repository.enqueueManifestChange(
      _session(),
      upserts: <PhotoEntry>[_entry('shared/相册/b.jpg', 2025)],
    );
    repository.enqueueManifestChange(
      _session(),
      deletes: <String>['shared/相册/gone.jpg'],
    );
    await repository.flushPendingManifestWrites();

    final written = PhotoManifest.decode(oss.uploads.last);
    final keys = written.entries.map((entry) => entry.key).toSet();
    expect(keys, containsAll(<String>['shared/相册/a.jpg', 'shared/相册/b.jpg']));
    expect(keys, isNot(contains('shared/相册/gone.jpg')));
  });

  test('同批次先删后传以 upsert 为准，删除意图正常生效', () async {
    final oss = _ImmediateManifestOss();
    final repository = PhotoIndexRepository(
      ossClient: oss,
      database: GalleryDatabase(),
    );

    repository.enqueueManifestChange(
      _session(),
      deletes: <String>['shared/相册/a.jpg'],
    );
    repository.enqueueManifestChange(
      _session(),
      upserts: <PhotoEntry>[_entry('shared/相册/a.jpg', 2026)],
    );
    repository.enqueueManifestChange(
      _session(),
      deletes: <String>['shared/相册/b.jpg', 'shared/相册/c.jpg'],
    );
    await repository.flushPendingManifestWrites();

    final written = PhotoManifest.decode(oss.uploads.last);
    final keys = written.entries.map((entry) => entry.key).toSet();
    expect(keys, contains('shared/相册/a.jpg'));
    expect(keys, isNot(contains('shared/相册/b.jpg')));
    expect(keys, isNot(contains('shared/相册/c.jpg')));
  });

  test('合并写冲突超限时本地索引标记待修复', () async {
    final oss = _AlwaysConflictOss();
    final database = _MemoryDatabase();
    final repository = PhotoIndexRepository(
      ossClient: oss,
      database: database,
    );

    repository.enqueueManifestChange(
      _session(),
      upserts: <PhotoEntry>[_entry('shared/相册/a.jpg', 2026)],
    );
    await repository.flushPendingManifestWrites();

    expect(database.meta?.needsRepair, isTrue);
  });
}
