import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/file_share/infrastructure/share_cache_store.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';

void main() {
  late Directory root;
  late ShareCacheStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pdd-share-cache-');
    store = ShareCacheStore(rootResolver: () => root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  FileItem itemFor(
    String name, {
    String? path,
    int? size,
    DateTime? updatedAt,
  }) {
    return FileItem(
      path: path ?? 'shared/$name',
      name: name,
      isDirectory: false,
      size: size,
      updatedAt: updatedAt ?? DateTime(2026, 10, 1),
    );
  }

  test('缓存按对象路径与版本建立独立目录并保留原始文件名', () async {
    final item = itemFor('报告.pdf', size: 4, updatedAt: DateTime(2026, 10, 1));
    final file = await store.fileFor(item);

    expect(file.path, contains('pdd_share_cache'));
    expect(
      file.parent.path.split(Platform.pathSeparator).last,
      ShareCacheStore.cacheDirectoryName(item),
    );
    expect(file.path.endsWith('${Platform.pathSeparator}报告.pdf'), isTrue);

    final newer = itemFor('报告.pdf', size: 4, updatedAt: DateTime(2026, 10, 2));
    final newerFile = await store.fileFor(newer);
    expect(newerFile.parent.path, isNot(file.parent.path));
  });

  test('文件名清洗：路径分隔符与非法字符替换，保留扩展名', () {
    expect(
      ShareCacheStore.sanitizeFileName('报告/2024:Q1?.pdf'),
      '2024_Q1_.pdf',
    );
    expect(ShareCacheStore.sanitizeFileName('a\\b*c.txt'), 'b_c.txt');
    expect(ShareCacheStore.sanitizeFileName('..'), 'file');
    expect(ShareCacheStore.sanitizeFileName('   '), 'file');

    final longName = '${'a' * 260}.pdf';
    final sanitized = ShareCacheStore.sanitizeFileName(longName);
    expect(sanitized.endsWith('.pdf'), isTrue);
    expect(sanitized.length, lessThan(longName.length));
  });

  test('命中返回缓存文件；大小不一致或文件缺失按未命中处理', () async {
    final item = itemFor('a.bin', size: 4);
    final target = await store.fileFor(item);
    await target.writeAsBytes(<int>[1, 2, 3, 4], flush: true);

    expect((await store.lookup(item))?.path, target.path);

    // 同版本缓存内容长度异常时删除并按未命中处理。
    await target.writeAsBytes(<int>[1, 2, 3], flush: true);
    expect(await store.lookup(item), isNull);
    expect(await target.exists(), isFalse);

    expect(await store.lookup(itemFor('missing.bin', size: 1)), isNull);
  });

  test('命中刷新最近访问时间', () async {
    final item = itemFor('a.bin', size: 2);
    final target = await store.fileFor(item);
    await target.writeAsBytes(<int>[1, 2], flush: true);
    final old = DateTime(2026, 1, 1);
    await target.setLastModified(old);

    final hit = await store.lookup(item);
    expect(hit, isNotNull);
    final modified = await target.lastModified();
    expect(modified.isAfter(old), isTrue);
  });

  test('临时文件提交后落定为正式缓存', () async {
    final item = itemFor('a.bin', size: 3);
    final target = await store.fileFor(item);
    final temporary = await store.temporaryFileFor(target);
    expect(temporary.path.endsWith('.part'), isTrue);
    await temporary.writeAsBytes(<int>[1, 2, 3], flush: true);

    final committed = await store.commit(temporary, target);
    expect(committed.path, target.path);
    expect(await target.exists(), isTrue);
    expect(await temporary.exists(), isFalse);
    expect(await target.length(), 3);
  });

  test('超期缓存被删除，未超期文件保留', () async {
    final now = DateTime(2026, 10, 24, 12);
    final expired = await store.fileFor(itemFor('old.bin', size: 2));
    await expired.writeAsBytes(<int>[1, 2], flush: true);
    await expired.setLastModified(now.subtract(const Duration(days: 8)));

    final fresh = await store.fileFor(itemFor('new.bin', size: 2));
    await fresh.writeAsBytes(<int>[1, 2], flush: true);
    await fresh.setLastModified(now.subtract(const Duration(days: 1)));

    final removed = await store.clean(now: now);
    expect(removed, 1);
    expect(await expired.exists(), isFalse);
    expect(await fresh.exists(), isTrue);
  });

  test('容量超限时按最旧优先删除，并跳过本次分享文件', () async {
    final now = DateTime(2026, 10, 24, 12);
    final limited = ShareCacheStore(
      rootResolver: () => root,
      capacityLimitBytes: 10,
    );
    final oldest = await limited.fileFor(itemFor('oldest.bin', size: 6));
    await oldest.writeAsBytes(<int>[1, 2, 3, 4, 5, 6], flush: true);
    await oldest.setLastModified(now.subtract(const Duration(hours: 2)));

    final newer = await limited.fileFor(itemFor('newer.bin', size: 6));
    await newer.writeAsBytes(<int>[1, 2, 3, 4, 5, 6], flush: true);
    await newer.setLastModified(now.subtract(const Duration(hours: 1)));

    final removed = await limited.clean(
      now: now,
      keepPaths: <String>{oldest.path},
    );
    expect(removed, 1);
    expect(await oldest.exists(), isTrue);
    expect(await newer.exists(), isFalse);
  });

  test('清理跳过 .part 临时文件', () async {
    final now = DateTime(2026, 10, 24, 12);
    final target = await store.fileFor(itemFor('a.bin', size: 1));
    final temporary = File('${target.path}.part');
    await temporary.writeAsBytes(<int>[1], flush: true);
    await temporary.setLastModified(now.subtract(const Duration(days: 30)));

    await store.clean(now: now);
    expect(await temporary.exists(), isTrue);
  });
}
