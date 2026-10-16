/// 目标路径已存在时的移动处置决策；不提供覆盖选项，避免破坏幂等重跑安全性。
enum MoveConflictResolution { skip, keepBoth }

class MoveProgress {
  const MoveProgress({
    required this.processed,
    required this.total,
    this.isUndo = false,
    this.isCounting = false,
  });

  final int processed;
  final int total;

  /// 撤销移动（反向搬回）与正向移动共用进度通道，文案据此区分。
  final bool isUndo;

  /// 仍在递归列举待迁移对象总数；为 true 时总数随每页列举结果递增，
  /// 列举完成后转为确定的「已处理/总数」。
  final bool isCounting;
}

class MoveSummary {
  const MoveSummary({
    required this.movedCount,
    required this.failedKeys,
    this.sourceKeys = const <String>{},
    this.destinationKeys = const <String>{},
  });

  final int movedCount;
  final List<String> failedKeys;

  /// 本次搬运涉及的源侧与目标侧对象 key（含目录标记），供索引挂钩使用。
  final Set<String> sourceKeys;
  final Set<String> destinationKeys;

  bool get hasFailures => failedKeys.isNotEmpty;
}
