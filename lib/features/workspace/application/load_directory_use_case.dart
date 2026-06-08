import '../domain/file_item.dart';
import '../infrastructure/file_repository.dart';

class LoadDirectoryUseCase {
  const LoadDirectoryUseCase(this._repository);

  final FileRepository _repository;

  Future<List<FileItem>> execute(String path) {
    return _repository.list(path);
  }
}
