import '../../../shared/state/app_controller.dart';
import '../domain/file_item.dart';

abstract class FileRepository {
  Future<List<FileItem>> list(String path);
  Future<void> createFolder(String name);
  Future<void> rename(FileItem item, String newName);
  Future<void> delete(FileItem item);
}

class MockFileRepository implements FileRepository {
  MockFileRepository(this._controller);

  final AppController _controller;

  @override
  Future<List<FileItem>> list(String path) => _controller.listDirectory(path);

  @override
  Future<void> createFolder(String name) => _controller.createFolder(name);

  @override
  Future<void> rename(FileItem item, String newName) =>
      _controller.renameItem(item, newName);

  @override
  Future<void> delete(FileItem item) => _controller.deleteItem(item);
}
