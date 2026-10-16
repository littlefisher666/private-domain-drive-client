import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../shared/path_utils.dart';
import '../../auth/application/session_controller.dart';
import '../../transfer/application/transfer_controller.dart';
import '../../workspace/application/workspace_controller.dart';
import '../domain/share_import_models.dart';

/// 分享导入域的编排层：批次渐进接收状态 + 确认上传。
///
/// 批次状态（待上传清单、目标目录、渐进接收进度）在本控制器内维护；
/// 确认上传时把待上传清单交给 [TransferController] 逐个入队，多文件
/// 归属同一上传批次。
class ShareImportController extends ChangeNotifier {
  ShareImportController({
    required SessionController sessionController,
    required WorkspaceController workspaceController,
    required TransferController transferController,
  })  : _sessionController = sessionController,
        _workspaceController = workspaceController,
        _transferController = transferController;

  final SessionController _sessionController;
  final WorkspaceController _workspaceController;
  final TransferController _transferController;

  List<ShareImportItem> _pendingShareItems = const <ShareImportItem>[];
  String _shareTargetPath = rootPrefix;

  /// 渐进接收中的分享批次状态；null 表示当前没有进行中/刚完成的批次。
  ShareImportBatchState? _activeShareBatch;

  /// 当前批次内已到达但尚未并入 [_pendingShareItems] 的暂存项。
  final List<ShareImportItem> _stagedShareItems = <ShareImportItem>[];

  /// 待弹目录选择弹窗的批次 id 列表（防重入签名来源）。
  final List<String> _shareBatchIds = <String>[];

  List<ShareImportItem> get pendingShareItems =>
      List<ShareImportItem>.unmodifiable(_pendingShareItems);
  String get shareTargetPath => _shareTargetPath;

  /// 当前渐进接收中的分享批次进度；批次完成后保留 finished 状态供
  /// 弹窗展示失败计数，直到确认/取消/新批次到来时清除。
  ShareImportBatchState? get activeShareBatch => _activeShareBatch;

  /// 待弹目录选择弹窗的批次 id；防重入签名以批次 id 为准。
  List<String> get pendingShareBatchIds =>
      List<String>.unmodifiable(_shareBatchIds);

  /// 重置分享导入状态：清空待上传项与批次进度。取消弹窗时调用，
  /// 进行中批次的后续事件将被忽略（用户已放弃该批内容）。
  void prepareShareImport({List<ShareImportItem>? items, String? targetPath}) {
    _pendingShareItems = List<ShareImportItem>.unmodifiable(
      items ?? const <ShareImportItem>[],
    );
    _shareTargetPath = normalizeDirPath(targetPath ?? rootPrefix);
    _clearShareBatchState();
    notifyListeners();
  }

  /// 会话变更后的分享导入复位：清空待上传项与批次进度。
  void handleSessionChanged() {
    _pendingShareItems = const <ShareImportItem>[];
    _clearShareBatchState();
  }

  /// 批次开始：记录批次进度，弹窗可先于复制完成弹出。
  void beginShareImportBatch(String batchId, int total) {
    if (batchId.isEmpty) return;
    final active = _activeShareBatch;
    if (active != null && !active.finished) {
      // 正常串行投递下不会出现；防御性并入旧批次结果后开启新批次。
      _finishActiveShareBatch(_stagedShareItems.length, 0);
    }
    _activeShareBatch = ShareImportBatchState(
      batchId: batchId,
      total: total,
      received: 0,
      finished: false,
      failedCount: 0,
    );
    _stagedShareItems.clear();
    if (!_shareBatchIds.contains(batchId)) {
      _shareBatchIds.add(batchId);
    }
    notifyListeners();
  }

  /// 批次内单个文件复制成功到达；不属于当前批次的到达项忽略。
  void addShareImportItem(String batchId, ShareImportItem item) {
    final batch = _activeShareBatch;
    if (batch == null || batch.finished || batch.batchId != batchId) {
      return;
    }
    _stagedShareItems.add(item);
    _activeShareBatch = ShareImportBatchState(
      batchId: batch.batchId,
      total: batch.total,
      received: _stagedShareItems.length,
      finished: false,
      failedCount: 0,
    );
    notifyListeners();
  }

  /// 批次完成：暂存项并入待上传清单；批次内全部失败时暂存项为空，
  /// 不进入待上传清单，仅保留失败计数供弹窗提示。
  void finishShareImportBatch(
    String batchId, {
    required int succeeded,
    required int failed,
  }) {
    final batch = _activeShareBatch;
    if (batch == null || batch.finished || batch.batchId != batchId) {
      return;
    }
    _finishActiveShareBatch(succeeded, failed);
  }

  void _finishActiveShareBatch(int succeeded, int failed) {
    final batch = _activeShareBatch;
    if (batch == null) return;
    _pendingShareItems = List<ShareImportItem>.unmodifiable(<ShareImportItem>[
      ..._pendingShareItems,
      ..._stagedShareItems,
    ]);
    _stagedShareItems.clear();
    _activeShareBatch = ShareImportBatchState(
      batchId: batch.batchId,
      total: batch.total,
      received: succeeded,
      finished: true,
      failedCount: failed,
    );
    notifyListeners();
  }

  /// 冷启动兜底：原生缓冲中已完整的批次直接并入待上传清单，
  /// 视为「立即完成」的批次；全失败批次（无任何成功项）不弹窗。
  void addCompletedShareBatch(ShareImportCompleteBatch batch) {
    if (batch.items.isEmpty) return;
    _pendingShareItems = List<ShareImportItem>.unmodifiable(<ShareImportItem>[
      ..._pendingShareItems,
      ...batch.items,
    ]);
    if (!_shareBatchIds.contains(batch.batchId)) {
      _shareBatchIds.add(batch.batchId);
    }
    notifyListeners();
  }

  void _clearShareBatchState() {
    _activeShareBatch = null;
    _stagedShareItems.clear();
    _shareBatchIds.clear();
  }

  void setShareTargetPath(String path) {
    _shareTargetPath = normalizeDirPath(path);
    notifyListeners();
  }

  Future<void> confirmShareUpload() async {
    _sessionController.ensureUploadCapability();
    if (_pendingShareItems.isEmpty) {
      throw StateError('没有待上传内容');
    }
    final items = _pendingShareItems;
    for (final item in items) {
      if (item.localPath.isEmpty || !await File(item.localPath).exists()) {
        throw StateError('分享文件“${item.name}”已不可用，请重新分享');
      }
    }
    _pendingShareItems = const <ShareImportItem>[];
    _clearShareBatchState();
    // 分享导入经传输队列异步完成，计数路径不可靠，失效目标目录由校准重建。
    _workspaceController.invalidateDirectorySummary(_shareTargetPath);
    _workspaceController.calibrateDirectorySummary(_shareTargetPath);
    notifyListeners();
    // 多文件分享导入归属同一批次，传输中心可展示整批上传汇总。
    final batchId = items.length > 1
        ? 'batch-${DateTime.now().microsecondsSinceEpoch}'
        : null;
    for (final item in items) {
      await _transferController.uploadFile(
        fileName: item.name,
        localPath: item.localPath,
        fileSize: item.size,
        targetPath: _shareTargetPath,
        batchId: batchId,
      );
    }
  }
}
