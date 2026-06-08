import '../domain/file_item.dart';

abstract class FileRepository {
  Future<List<FileItem>> list(String path);
}

class StaticFileRepository implements FileRepository {
  const StaticFileRepository();

  static final Map<String, List<FileItem>> _directories = {
    'shared/': <FileItem>[
      FileItem(
        path: 'shared/common/',
        name: 'common',
        isDirectory: true,
        updatedAt: DateTime(2026, 6, 1, 10, 0),
      ),
      FileItem(
        path: 'shared/photos/',
        name: 'photos',
        isDirectory: true,
        updatedAt: DateTime(2026, 6, 2, 9, 30),
      ),
      FileItem(
        path: 'shared/docs/',
        name: 'docs',
        isDirectory: true,
        updatedAt: DateTime(2026, 6, 3, 14, 20),
      ),
      FileItem(
        path: 'shared/readme.txt',
        name: 'readme.txt',
        isDirectory: false,
        size: 2048,
        updatedAt: DateTime(2026, 6, 4, 8, 45),
      ),
    ],
    'shared/common/': <FileItem>[
      FileItem(
        path: 'shared/common/family-rules.pdf',
        name: 'family-rules.pdf',
        isDirectory: false,
        size: 248320,
        updatedAt: DateTime(2026, 5, 28, 19, 10),
      ),
      FileItem(
        path: 'shared/common/receipts/',
        name: 'receipts',
        isDirectory: true,
        updatedAt: DateTime(2026, 6, 1, 11, 0),
      ),
      FileItem(
        path: 'shared/common/access-guide.txt',
        name: 'access-guide.txt',
        isDirectory: false,
        size: 4096,
        updatedAt: DateTime(2026, 6, 1, 18, 20),
      ),
    ],
    'shared/common/receipts/': <FileItem>[
      FileItem(
        path: 'shared/common/receipts/2026-05.pdf',
        name: '2026-05.pdf',
        isDirectory: false,
        size: 156000,
        updatedAt: DateTime(2026, 5, 31, 20, 15),
      ),
      FileItem(
        path: 'shared/common/receipts/2026-06.pdf',
        name: '2026-06.pdf',
        isDirectory: false,
        size: 168400,
        updatedAt: DateTime(2026, 6, 3, 20, 15),
      ),
    ],
    'shared/photos/': <FileItem>[
      FileItem(
        path: 'shared/photos/2026-trip.jpg',
        name: '2026-trip.jpg',
        isDirectory: false,
        size: 3145728,
        updatedAt: DateTime(2026, 6, 5, 17, 12),
      ),
      FileItem(
        path: 'shared/photos/portraits/',
        name: 'portraits',
        isDirectory: true,
        updatedAt: DateTime(2026, 6, 5, 17, 0),
      ),
    ],
    'shared/photos/portraits/': <FileItem>[
      FileItem(
        path: 'shared/photos/portraits/alice.png',
        name: 'alice.png',
        isDirectory: false,
        size: 1245728,
        updatedAt: DateTime(2026, 6, 5, 17, 6),
      ),
      FileItem(
        path: 'shared/photos/portraits/bob.jpg',
        name: 'bob.jpg',
        isDirectory: false,
        size: 1457280,
        updatedAt: DateTime(2026, 6, 5, 17, 8),
      ),
    ],
    'shared/docs/': <FileItem>[
      FileItem(
        path: 'shared/docs/project-plan.md',
        name: 'project-plan.md',
        isDirectory: false,
        size: 8192,
        updatedAt: DateTime(2026, 6, 3, 21, 5),
      ),
      FileItem(
        path: 'shared/docs/server-config.json',
        name: 'server-config.json',
        isDirectory: false,
        size: 3072,
        updatedAt: DateTime(2026, 6, 2, 16, 40),
      ),
    ],
  };

  @override
  Future<List<FileItem>> list(String path) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return List<FileItem>.unmodifiable(_directories[path] ?? const <FileItem>[]);
  }
}
