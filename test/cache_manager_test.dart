import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/file_share/infrastructure/share_cache_store.dart';
import 'package:private_domain_drive_client/features/gallery/infrastructure/gallery_database.dart';
import 'package:private_domain_drive_client/features/gallery/infrastructure/original_cache_store.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/shared/cache/cache_manager.dart';
import 'package:private_domain_drive_client/shared/cache/disk_document_cache.dart';
import 'package:private_domain_drive_client/shared/cache/disk_image_cache.dart';

void main() {
  late Directory root;
  late DiskImageCache imageCache;
  late DiskDocumentCache documentCache;
  late ShareCacheStore shareCacheStore;
  late OriginalCacheStore originalCacheStore;
  late CacheManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pdd-cache-manager-');
    imageCache = DiskImageCache(rootResolver: () => root);
    documentCache = DiskDocumentCache(rootResolver: () => root);
    shareCacheStore = ShareCacheStore(rootResolver: () => root);
    originalCacheStore = OriginalCacheStore(
      GalleryDatabase(),
      rootResolver: () => root,
    );
    manager = CacheManager(
      imageCache: imageCache,
      documentCache: documentCache,
      shareCacheStore: shareCacheStore,
      originalCacheStore: () => originalCacheStore,
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('汇总四类缓存占用并统一清理', () async {
    await imageCache.write(
      DiskImageCacheKind.thumbnails,
      'thumb',
      List<int>.filled(100, 1),
    );
    await imageCache.write(
      DiskImageCacheKind.previews,
      'preview',
      List<int>.filled(200, 1),
    );

    final documentTemp = await documentCache.createTemporaryFile();
    await documentTemp!.writeAsBytes(List<int>.filled(300, 1));
    await documentCache.commit('doc', documentTemp);

    final shareFile = await shareCacheStore.fileFor(
      const FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
    );
    await shareFile.writeAsBytes(List<int>.filled(400, 1));

    final originalFile = await originalCacheStore.fileFor('shared/photo.jpg');
    await originalFile.writeAsBytes(List<int>.filled(500, 1));

    expect(await manager.sizeBytes(), 1500);
    expect(await imageCache.sizeBytes(), 300);
    expect(await documentCache.sizeBytes(), 300);
    expect(await shareCacheStore.sizeBytes(), 400);
    expect(await originalCacheStore.sizeBytes(), 500);

    final freed = await manager.clear();

    expect(freed, 1500);
    expect(await manager.sizeBytes(), 0);
    expect(await shareFile.exists(), isFalse);
    expect(await originalFile.exists(), isFalse);
  });

  test('清理后缓存仍可重新写入', () async {
    await imageCache.write(
      DiskImageCacheKind.thumbnails,
      'thumb',
      List<int>.filled(64, 1),
    );
    await manager.clear();

    await imageCache.write(
      DiskImageCacheKind.thumbnails,
      'thumb',
      List<int>.filled(32, 1),
    );
    expect(await imageCache.sizeBytes(), 32);
    expect(
      await imageCache.read(DiskImageCacheKind.thumbnails, 'thumb'),
      hasLength(32),
    );
  });

  test('缓存大小格式化', () {
    expect(formatCacheSize(0), '0 B');
    expect(formatCacheSize(512), '512 B');
    expect(formatCacheSize(1024), '1.0 KB');
    expect(formatCacheSize(1536), '1.5 KB');
    expect(formatCacheSize(128 * 1024 * 1024), '128.0 MB');
  });
}
