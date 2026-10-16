import 'file_item.dart';

class BatchDeletePreview {
  const BatchDeletePreview({
    required this.selectedCount,
    required this.directoryCount,
    required this.objectPaths,
    required this.items,
    this.topLevelPaths = const <String>{},
  });

  final int selectedCount;
  final int directoryCount;
  final Set<String> objectPaths;

  /// 用户勾选的顶层条目，逐项建立独立回收条目时用于对象归属分组。
  final List<FileItem> items;

  /// 用户勾选的顶层条目路径（不含目录展开结果），供统计缓存按目录修正。
  final Set<String> topLevelPaths;
  int get objectCount => objectPaths.length;
}

class BatchDeleteSummary {
  const BatchDeleteSummary({
    required this.deletedPaths,
    required this.failedPaths,
  });

  final List<String> deletedPaths;
  final List<String> failedPaths;
}

/// 删除（移入回收站）进行中状态；total 为 0 表示仍在统计待删除对象。
class DeleteProgress {
  const DeleteProgress({required this.processed, required this.total});

  final int processed;
  final int total;
}
