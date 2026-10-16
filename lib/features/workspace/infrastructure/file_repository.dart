import '../application/recycle_bin_controller.dart';
import '../application/workspace_controller.dart';
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

/// Mock 仓库：目录浏览与统计取自 [WorkspaceController]，
/// 删除（移入回收站）编排取自 RecycleBinController。
class MockFileRepository implements FileRepository {
  MockFileRepository(this._workspaceController, this._recycleBinController);

  final WorkspaceController _workspaceController;
  final RecycleBinController _recycleBinController;

  @override
  Future<List<FileItem>> list(String path) =>
      _workspaceController.listDirectory(path);

  @override
  Future<void> createFolder(String name) =>
      _workspaceController.createFolder(name);

  @override
  Future<void> rename(FileItem item, String newName) =>
      _workspaceController.renameItem(item, newName);

  @override
  Future<void> delete(FileItem item) => _recycleBinController.deleteItem(item);

  @override
  Future<DirectorySummary?> cachedSummary(String path) =>
      _workspaceController.cachedDirectorySummary(path);

  @override
  Future<Map<String, DirectorySummary>> cachedSummaries(
          Iterable<String> paths) =>
      _workspaceController.cachedDirectorySummaries(paths);

  @override
  Future<void> refreshSummaries(
    Iterable<String> paths, {
    required void Function(String path, DirectorySummary summary) onResult,
  }) =>
      _workspaceController.refreshDirectorySummaries(paths, onResult: onResult);
}
