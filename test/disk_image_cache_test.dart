import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/shared/cache/disk_image_cache.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('pdd-disk-cache-test-');
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  DiskImageCache buildCache({int thumbnailByteLimit = 1024 * 1024}) {
    return DiskImageCache(
      rootResolver: () => tempRoot,
      thumbnailByteLimit: thumbnailByteLimit,
      previewByteLimit: thumbnailByteLimit,
    );
  }

  test('写入后读取命中', () async {
    final cache = buildCache();
    await cache.write(
      DiskImageCacheKind.thumbnails,
      'key-a',
      <int>[1, 2, 3, 4],
    );

    final bytes = await cache.read(DiskImageCacheKind.thumbnails, 'key-a');
    expect(bytes, <int>[1, 2, 3, 4]);
  });

  test('对象版本变化生成新缓存键', () {
    final base = {
      'namespace': 'bucket|user',
      'path': 'shared/photo.jpg',
      'process': 'image/resize,m_lfit,w_320,h_320',
    };
    final first = DiskImageCache.cacheKey(
      namespace: base['namespace']!,
      path: base['path']!,
      versionToken: '1024|2026-08-01T00:00:00Z',
      process: base['process']!,
    );
    final second = DiskImageCache.cacheKey(
      namespace: base['namespace']!,
      path: base['path']!,
      versionToken: '2048|2026-08-02T00:00:00Z',
      process: base['process']!,
    );

    expect(first, isNot(second));
  });

  test('空字节不写入缓存', () async {
    final cache = buildCache();
    await cache.write(DiskImageCacheKind.thumbnails, 'key-empty', <int>[]);

    final bytes = await cache.read(DiskImageCacheKind.thumbnails, 'key-empty');
    expect(bytes, isNull);
  });

  test('超过字节上限时按最近使用淘汰旧条目', () async {
    final cache = buildCache(thumbnailByteLimit: 6);
    await cache.write(DiskImageCacheKind.thumbnails, 'old', <int>[1, 2, 3, 4]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await cache.write(DiskImageCacheKind.thumbnails, 'new', <int>[5, 6, 7, 8]);

    final oldBytes = await cache.read(DiskImageCacheKind.thumbnails, 'old');
    final newBytes = await cache.read(DiskImageCacheKind.thumbnails, 'new');
    expect(oldBytes, isNull);
    expect(newBytes, <int>[5, 6, 7, 8]);
  });

  test('缓存文件被删除后读取降级为未命中', () async {
    final cache = buildCache();
    await cache.write(DiskImageCacheKind.thumbnails, 'gone', <int>[9, 9]);

    final directory = Directory(
      '${tempRoot.path}/pdd_image_cache/thumbnails',
    );
    await for (final entity in directory.list()) {
      if (entity is File && !entity.path.endsWith('.tmp')) {
        await entity.delete();
      }
    }

    final bytes = await cache.read(DiskImageCacheKind.thumbnails, 'gone');
    expect(bytes, isNull);
  });

  test('缓存目录不可用时读写静默失败', () async {
    final blocker = await File('${tempRoot.path}/blocked').create();
    var failed = false;
    final cache = DiskImageCache(
      rootResolver: () {
        // 返回被文件占用的路径，目录创建必然失败。
        try {
          return Directory(blocker.path);
        } catch (_) {
          failed = true;
          return null;
        }
      },
    );

    await cache.write(DiskImageCacheKind.previews, 'key', <int>[1, 2, 3]);
    final bytes = await cache.read(DiskImageCacheKind.previews, 'key');

    expect(failed, isFalse);
    expect(bytes, isNull);
  });

  test('不同 kind 的缓存互相隔离', () async {
    final cache = buildCache();
    await cache.write(DiskImageCacheKind.thumbnails, 'same-key', <int>[1]);
    await cache.write(DiskImageCacheKind.previews, 'same-key', <int>[2]);

    final thumbnail = await cache.read(DiskImageCacheKind.thumbnails, 'same-key');
    final preview = await cache.read(DiskImageCacheKind.previews, 'same-key');
    expect(thumbnail, <int>[1]);
    expect(preview, <int>[2]);
  });
}
