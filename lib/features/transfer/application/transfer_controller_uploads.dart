part of 'transfer_controller.dart';

// TransferController 的上传闭环：staging 迁移、上传执行闭包、上传冲突
// 对话框与批次「整批应用」决策、保留两者的可用对象键探测。
// 私有成员经 part 与主文件共享；控制器私有字段以抽象 getter 声明，
// 由 TransferController 的具体字段实现。

/// 视频扩展名：上传前需要异步准备缩略图（截帧）。
const _videoFileExtensions = <String>{
  'mp4', 'mov', 'm4v', 'mkv', 'avi', 'webm', '3gp',
};

/// 图片扩展名：超大图片上传前需要在本地生成缩略图。
const _imageFileExtensions = <String>{
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp',
};

mixin _TransferUploads on ChangeNotifier {
  SessionController get _sessionController;
  WorkspaceController get _workspaceController;
  OssClient get _ossClient;
  TransferQueue get _transferQueue;
  UploadStaging? get _uploadStaging;
  GlobalKey<NavigatorState>? get _navigatorKey;
  GalleryIndexHooks? get _galleryHooks;
  Map<String, UploadConflictResolution> get _batchConflictResolutions;
  Map<String, Completer<_UploadConflictDecision?>> get _batchConflictWaiters;

  /// staging 迁移失败不阻塞上传：降级为使用原路径。
  Future<String> _migrateToStagingSafe(String localPath, String taskId) async {
    final staging = _uploadStaging;
    if (staging == null) return localPath;
    try {
      return await staging.migrateIfNeeded(localPath, taskId);
    } catch (_) {
      return localPath;
    }
  }

  /// 构造上传执行闭包：uploadFile 入队与「已中断任务继续上传」共用，
  /// 冲突解析、会话恢复与媒体索引挂钩行为保持一致。
  QueuedTransfer _buildUploadClosure({
    required String taskId,
    required String fileName,
    required String localPath,
    required String dir,
    String? batchId,
  }) {
    return QueuedTransfer((report, isCanceled) async {
      if (isCanceled()) throw const TransferCanceledException();
      await _sessionController.ensureSessionReady();
      final session = _sessionController.requireSession();
      var objectPath = '$dir$fileName';
      // 上传前校验目标是否已存在；放在队列闭包内使重试同样经过校验。
      if (await _ossClient.objectExists(objectPath, session)) {
        final resolution = await _resolveUploadConflict(
          batchId: batchId,
          fileName: fileName,
          targetDisplayPath: _workspaceController.displayPath(dir),
        );
        if (isCanceled()) throw const TransferCanceledException();
        switch (resolution) {
          case UploadConflictResolution.skip:
            throw const UploadSkippedException();
          case UploadConflictResolution.overwrite:
            break;
          case UploadConflictResolution.keepBoth:
            objectPath = await _availableUploadPath(objectPath, session);
        }
      }
      if (isCanceled()) throw const TransferCanceledException();
      // 视频上传前启动截帧，超大图片上传前本地生成缩略图，均与上传
      // 并行准备；失败不影响上传本身。
      Future<String?>? thumbnailFuture;
      final extension = fileName.split('.').last.toLowerCase();
      if (_videoFileExtensions.contains(extension)) {
        thumbnailFuture =
            _galleryHooks?.prepareVideoThumbnail(objectPath, localPath);
      } else if (_imageFileExtensions.contains(extension)) {
        thumbnailFuture =
            _galleryHooks?.prepareImageThumbnail(objectPath, localPath);
      }
      await _ossClient.uploadFile(
        objectPath,
        localPath,
        session,
        taskId: taskId,
        onProgress: report,
      );
      if (isCanceled()) throw const TransferCanceledException();
      _workspaceController.noteDirectoryFilesAdded(dir, 1, DateTime.now());
      _workspaceController.calibrateDirectorySummary(dir);
      _workspaceController.bumpTreeRevision();
      _workspaceController.clearDirectorySizeCache();
      notifyListeners();
      // 上传成功后触发索引增量更新；挂钩在后台执行，不阻塞任务
      // 完成状态、不占用传输并发槽，挂钩异常不影响任务成功状态。
      if (_galleryHooks != null) {
        final hooks = _galleryHooks!;
        unawaited(() async {
          String? thumbPath;
          try {
            thumbPath = await thumbnailFuture;
          } catch (_) {
            thumbPath = null;
          }
          try {
            await hooks.onMediaUploaded(
              objectPath: objectPath,
              localPath: localPath,
              thumbLocalPath: thumbPath,
            );
          } catch (error) {
            debugPrint('[gallery] 索引增量更新挂钩失败: $error');
          }
        }());
      }
    });
  }

  /// 解析上传冲突的处置决策；同批任务通过共享 Completer 保证只弹一次对话框。
  Future<UploadConflictResolution> _resolveUploadConflict({
    required String? batchId,
    required String fileName,
    required String targetDisplayPath,
  }) async {
    final decision = await _requestUploadConflictDecision(
      batchId: batchId,
      fileName: fileName,
      targetDisplayPath: targetDisplayPath,
    );
    return decision.resolution;
  }

  Future<_UploadConflictDecision> _requestUploadConflictDecision({
    required String? batchId,
    required String fileName,
    required String targetDisplayPath,
  }) async {
    if (batchId == null) {
      final result = await _showUploadConflictDialog(
        fileName: fileName,
        targetDisplayPath: targetDisplayPath,
        batchPendingCount: null,
      );
      // 对话框不可用或被系统返回键关闭时按跳过处理，不做覆盖性写入。
      return result ??
          (resolution: UploadConflictResolution.skip, applyToBatch: false);
    }
    final cached = _batchConflictResolutions[batchId];
    if (cached != null) {
      return (resolution: cached, applyToBatch: true);
    }
    final isFirstAsker = !_batchConflictWaiters.containsKey(batchId);
    final waiter = _batchConflictWaiters.putIfAbsent(
      batchId,
      () => Completer<_UploadConflictDecision?>(),
    );
    if (!isFirstAsker) {
      final result = await waiter.future;
      if (result != null) return result;
      // 未勾选整批应用时该批次无统一决策，为当前任务重新询问。
      return _requestUploadConflictDecision(
        batchId: batchId,
        fileName: fileName,
        targetDisplayPath: targetDisplayPath,
      );
    }
    final batchPendingCount = _transferQueue.tasks
            .where((task) =>
                task.batchId == batchId &&
                task.status != TransferTaskStatus.success &&
                task.status != TransferTaskStatus.failed &&
                task.status != TransferTaskStatus.canceled)
            .length -
        1;
    final result = await _showUploadConflictDialog(
      fileName: fileName,
      targetDisplayPath: targetDisplayPath,
      batchPendingCount: batchPendingCount <= 0 ? null : batchPendingCount,
    );
    if (result != null && result.applyToBatch) {
      _batchConflictResolutions[batchId] = result.resolution;
    }
    _batchConflictWaiters.remove(batchId);
    waiter.complete(result != null && result.applyToBatch ? result : null);
    return result ??
        (resolution: UploadConflictResolution.skip, applyToBatch: false);
  }

  Future<_UploadConflictDecision?> _showUploadConflictDialog({
    required String fileName,
    required String targetDisplayPath,
    required int? batchPendingCount,
  }) async {
    final context = _navigatorKey?.currentContext;
    if (context == null) return null;
    var selected = UploadConflictResolution.skip;
    var applyToBatch = false;
    return showDialog<_UploadConflictDecision>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: const Text('云端已存在同名文件'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('「$fileName」在「$targetDisplayPath」已存在，请选择处理方式。'),
              RadioGroup<UploadConflictResolution>(
                groupValue: selected,
                onChanged: (value) =>
                    setState(() => selected = value ?? selected),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    RadioListTile<UploadConflictResolution>(
                      title: const Text('保留两者'),
                      subtitle: const Text('自动追加序号后上传，云端原文件保持不变'),
                      value: UploadConflictResolution.keepBoth,
                    ),
                    RadioListTile<UploadConflictResolution>(
                      title: const Text('覆盖'),
                      subtitle: const Text('替换云端已有的同名文件'),
                      value: UploadConflictResolution.overwrite,
                    ),
                    RadioListTile<UploadConflictResolution>(
                      title: const Text('跳过'),
                      subtitle: const Text('不上传，任务直接标记完成'),
                      value: UploadConflictResolution.skip,
                    ),
                  ],
                ),
              ),
              if (batchPendingCount != null)
                CheckboxListTile(
                  value: applyToBatch,
                  onChanged: (value) =>
                      setState(() => applyToBatch = value ?? false),
                  title: Text('同批其余 $batchPendingCount 个文件应用相同处理'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                (resolution: selected, applyToBatch: applyToBatch),
              ),
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
  }

  /// 探测「文件名（1）」样式的可用对象键，用于保留两者上传。
  Future<String> _availableUploadPath(
      String desired, UserSession session) async {
    final directory = parentPathOf(desired);
    final name = desired.substring(directory.length);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var number = 1;; number++) {
      final candidate = '$directory$stem（$number）$extension';
      if (!await _ossClient.objectExists(candidate, session)) return candidate;
    }
  }
}
