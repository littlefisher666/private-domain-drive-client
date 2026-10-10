import '../../../shared/state/app_controller.dart';
import '../domain/file_item.dart';
import 'oss_client.dart';

abstract class FileRepository {
  Future<List<FileItem>> list(String path);
  Future<void> createFolder(String name);
  Future<void> rename(FileItem item, String newName);
  Future<void> delete(FileItem item);

  /// 目录统计懒加载能力：缓存命中读取与后台受限并发刷新。
  Future<DirectorySummary?> cachedSummary(String path);
  Future<Map<String, DirectorySummary>> cachedSummaries(
      Iterable<String> paths);
  Future<void> refreshSummaries(
    Iterable<String> paths, {
    required void Function(String path, DirectorySummary summary) onResult,
  });
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

  @override
  Future<DirectorySummary?> cachedSummary(String path) =>
      _controller.cachedDirectorySummary(path);

  @override
  Future<Map<String, DirectorySummary>> cachedSummaries(
          Iterable<String> paths) =>
      _controller.cachedDirectorySummaries(paths);

  @override
  Future<void> refreshSummaries(
    Iterable<String> paths, {
    required void Function(String path, DirectorySummary summary) onResult,
  }) =>
      _controller.refreshDirectorySummaries(paths, onResult: onResult);
}
