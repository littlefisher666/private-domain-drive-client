import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';

void main() {
  test('拍摄时间排序保持文件夹在前，缺少 EXIF 的文件排在最后', () {
    final items = sortFileItems(<FileItem>[
      FileItem(
        path: 'shared/no-exif.jpg',
        name: 'no-exif.jpg',
        isDirectory: false,
        updatedAt: DateTime(2026, 9, 9),
      ),
      FileItem(
        path: 'shared/older.jpg',
        name: 'older.jpg',
        isDirectory: false,
        takenAt: DateTime(2026, 9, 1),
      ),
      FileItem(
        path: 'shared/newer.jpg',
        name: 'newer.jpg',
        isDirectory: false,
        takenAt: DateTime(2026, 9, 3),
      ),
      const FileItem(path: 'shared/photos/', name: 'photos', isDirectory: true),
    ], FileSortOption.takenNewest);

    expect(items.map((item) => item.name), <String>[
      'photos',
      'newer.jpg',
      'older.jpg',
      'no-exif.jpg',
    ]);
  });

  test('名称排序支持降序', () {
    final items = sortFileItems(<FileItem>[
      const FileItem(path: 'shared/a', name: 'alpha', isDirectory: false),
      const FileItem(path: 'shared/b', name: 'beta', isDirectory: false),
    ], FileSortOption.nameDescending);

    expect(items.map((item) => item.name), <String>['beta', 'alpha']);
  });
}
