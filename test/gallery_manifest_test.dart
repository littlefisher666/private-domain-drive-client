import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/gallery/domain/photo_entry.dart';
import 'package:private_domain_drive_client/features/gallery/domain/photo_manifest.dart';
import 'package:private_domain_drive_client/features/gallery/infrastructure/gallery_database.dart';
import 'package:private_domain_drive_client/features/gallery/infrastructure/photo_index_repository.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_oss/private_domain_oss.dart';

class _FakeManifestOss extends OssClient {
  _FakeManifestOss({required this.etags, this.content});

  /// 每次 loadManifest（列举）看到的清单 ETag 序列。
  final List<String> etags;
  String? content;
  final List<String> uploads = <String>[];
  int loadCalls = 0;

  @override
  Future<List<OssNativeObject>> listAllObjects(
    String path,
    UserSession session,
  ) async {
    if (loadCalls >= etags.length) {
      throw StateError('意外的清单读取：第 ${loadCalls + 1} 次');
    }
    final etag = etags[loadCalls];
    loadCalls++;
    return <OssNativeObject>[
      OssNativeObject(key: path, size: 10, etag: etag),
    ];
  }

  @override
  Future<List<int>> download(String path, UserSession session) async {
    final raw = content;
    if (raw == null) throw StateError('清单对象不存在');
    return utf8.encode(raw);
  }

  @override
  Future<void> uploadText(
    String path,
    String content,
    UserSession session,
  ) async {
    uploads.add(content);
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

PhotoEntry _entry(String key, int year, {String? thumbKey}) {
  return PhotoEntry(
    key: key,
    mediaType: PhotoMediaType.image,
    takenAt: DateTime(year, 6, 1),
    size: 1024,
    directory: 'shared/相册/',
    thumbKey: thumbKey,
    width: 100,
    height: 80,
    latitude: 34.2,
    longitude: 108.9,
    device: 'macOS',
  );
}

void main() {
  test('清单往返保留 GPS、上传设备与缩略图映射', () {
    final entry = _entry(
      'shared/相册/a.jpg',
      2026,
      thumbKey: 'shared/thumbs/shared/相册/a.jpg.jpg',
    );
    final manifest = PhotoManifest(
      version: 3,
      scannedAt: DateTime(2026, 9, 1, 10),
      needsRepair: false,
      entries: <PhotoEntry>[entry],
    );

    final decoded = PhotoManifest.decode(manifest.encode());

    expect(decoded.version, 3);
    expect(decoded.entries.single.key, entry.key);
    expect(decoded.entries.single.thumbKey, entry.thumbKey);
    expect(decoded.entries.single.latitude, 34.2);
    expect(decoded.entries.single.longitude, 108.9);
    expect(decoded.entries.single.device, 'macOS');
  });

  test('清单 JSON 损坏时增量写入立即放弃并交由全量扫描修复', () async {
    final oss = _FakeManifestOss(etags: <String>['e1'])
      ..content = '{broken json';
    final repository = PhotoIndexRepository(
      ossClient: oss,
      database: GalleryDatabase(),
    );

    final result = await repository.updateManifest(
      _session(),
      (manifest) => manifest,
    );

    expect(result, ManifestWriteResult.conflictExceeded);
    expect(oss.uploads, isEmpty);
  });

  test('写入前发现 ETag 变化时退避重试并成功写入', () async {
    // 第一次读取 etag=e1，复查发现 e2（并发写入）→ 重试；
    // 第二次读取 e2、复查 e2 一致 → 写入成功。
    final oss = _FakeManifestOss(
      etags: <String>['e1', 'e2', 'e2'],
      content: PhotoManifest(
        version: 1,
        scannedAt: null,
        needsRepair: false,
        entries: const <PhotoEntry>[],
      ).encode(),
    );
    final repository = PhotoIndexRepository(
      ossClient: oss,
      database: GalleryDatabase(),
    );

    final result = await repository.updateManifest(
      _session(),
      (manifest) => PhotoManifest(
        version: manifest.version,
        scannedAt: manifest.scannedAt,
        needsRepair: false,
        entries: <PhotoEntry>[_entry('shared/相册/new.jpg', 2026)],
      ),
    );

    expect(result, ManifestWriteResult.success);
    expect(oss.uploads, hasLength(1));
    final written = PhotoManifest.decode(oss.uploads.single);
    expect(written.version, 2);
    expect(written.entries.single.key, 'shared/相册/new.jpg');
  });

  test('ETag 持续冲突超过重试上限时放弃写入', () async {
    // 每次读取与复查之间 ETag 都被并发修改：读取序列 e1/e2/e3，
    // 复查看到的总是更新的 e2/e3/e4。
    final oss = _FakeManifestOss(
      etags: <String>['e1', 'e2', 'e2', 'e3', 'e3', 'e4'],
      content: PhotoManifest(
        version: 1,
        scannedAt: null,
        needsRepair: false,
        entries: const <PhotoEntry>[],
      ).encode(),
    );
    final repository = PhotoIndexRepository(
      ossClient: oss,
      database: GalleryDatabase(),
    );

    final result = await repository.updateManifest(
      _session(),
      (manifest) => manifest,
    );

    expect(result, ManifestWriteResult.conflictExceeded);
    expect(oss.uploads, isEmpty);
  });
}
