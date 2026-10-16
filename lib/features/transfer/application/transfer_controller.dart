import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../shared/gallery_index_hooks.dart';
import '../../../shared/path_utils.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/user_session.dart';
import '../../workspace/application/workspace_controller.dart';
import '../../workspace/domain/file_item.dart';
import '../../workspace/infrastructure/oss_client.dart';
import '../domain/transfer_enqueue.dart';
import '../domain/transfer_task.dart';
import '../infrastructure/upload_staging.dart';
import 'transfer_queue.dart';

typedef _UploadConflictDecision
    = ({UploadConflictResolution resolution, bool applyToBatch});

/// 传输任务控制器：上传/下载任务入队与执行闭包、上传冲突处置、
/// 重试/续传/取消/暂停与已完成任务清理。任务表与队列调度由
/// [TransferQueue] 持有，本控制器只承载任务级操作。
class TransferController extends ChangeNotifier {
  TransferController({
    required SessionController sessionController,
    required WorkspaceController workspaceController,
    required TransferQueue transferQueue,
    required OssClient ossClient,
    UploadStaging? uploadStaging,
  })  : _sessionController = sessionController,
        _workspaceController = workspaceController,
        _transferQueue = transferQueue,
        _ossClient = ossClient,
        // testWidgets（FakeAsync）环境下未 mock 的 platform channel 永远
        // 不会回复，path_provider 调用会阻塞入队路径；测试默认禁用 staging
        // 迁移以保持与改造前一致的同步入队行为，需要验证 staging 的测试
        // 应显式注入 UploadStaging 假实现。
        _uploadStaging = uploadStaging ??
            (Platform.environment.containsKey('FLUTTER_TEST')
                ? null
                : UploadStaging()) {
    _transferQueue.onTaskSucceeded = _cleanupStagingForTask;
  }

  final SessionController _sessionController;
  final WorkspaceController _workspaceController;
  final TransferQueue _transferQueue;
  final OssClient _ossClient;
  final UploadStaging? _uploadStaging;

  /// 全局 Navigator Key，供传输队列内弹出上传冲突处置对话框。
  GlobalKey<NavigatorState>? _navigatorKey;
  GalleryIndexHooks? _galleryHooks;

  /// 批次级「整批应用」决策；同批其余已存在任务直接复用。
  final Map<String, UploadConflictResolution> _batchConflictResolutions =
      <String, UploadConflictResolution>{};

  /// 正在等待批次决策的任务共享同一个 Completer，保证一批只弹一次对话框。
  final Map<String, Completer<_UploadConflictDecision?>>
      _batchConflictWaiters = <String, Completer<_UploadConflictDecision?>>{};

  static const _videoFileExtensions = <String>{
    'mp4', 'mov', 'm4v', 'mkv', 'avi', 'webm', '3gp',
  };
  static const _imageFileExtensions = <String>{
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp',
  };

  void setNavigatorKey(GlobalKey<NavigatorState>? key) {
    _navigatorKey = key;
  }

  /// 注入相册索引挂钩（上传增量更新、删除清理、还原恢复）。
  void setGalleryHooks(GalleryIndexHooks? hooks) {
    _galleryHooks = hooks;
  }

  /// 会话清除前重置批次冲突决策，避免跨会话复用旧决策。
  void clearBatchConflictState() {
    _batchConflictResolutions.clear();
  }

  Future<void> uploadFile(
      {required String fileName,
      required String localPath,
      required int fileSize,
      String? targetPath,
      String? batchId}) async {
    _sessionController.ensureUploadCapability();
    final dir =
        normalizeDirPath(targetPath ?? _workspaceController.currentPath);
    final taskId = _transferQueue.newTransferId('upload');
    // 缓存目录中的源文件（系统分享、部分选择器结果）先迁移到持久 staging
    // 目录，应用被杀后源文件不随 cacheDir 清理而丢失。
    final stagedPath = await _migrateToStagingSafe(localPath, taskId);
    _transferQueue.enqueue(
      TransferTask(
        id: taskId,
        name: fileName,
        type: TransferTaskType.upload,
        status: TransferTaskStatus.pending,
        progress: 0,
        target: _workspaceController.displayPath(dir),
        targetDir: dir,
        sourcePath: stagedPath,
        batchId: batchId,
        totalBytes: fileSize,
      ),
      _buildUploadClosure(
        taskId: taskId,
        fileName: fileName,
        localPath: stagedPath,
        dir: dir,
        batchId: batchId,
      ),
    );
  }

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

  Future<List<int>> downloadBytes(FileItem item) async {
    if (!_sessionController.capabilities.download) {
      throw StateError('当前身份没有下载权限');
    }
    if (item.isDirectory) {
      throw StateError('一期不支持文件夹下载');
    }

    await _sessionController.ensureSessionReady();
    return _ossClient.download(item.path, _sessionController.requireSession());
  }

  String enqueueDownload(
    FileItem item, {
    required String targetDirectory,
    String? batchId,
  }) {
    if (!_sessionController.capabilities.download) {
      throw StateError('当前身份没有下载权限');
    }
    if (item.isDirectory) {
      throw StateError('文件夹不支持直接下载');
    }
    _workspaceController.ensureWithinRoot(item.path);
    final taskId = _transferQueue.newTransferId('download');
    _transferQueue.enqueue(
      TransferTask(
        id: taskId,
        name: item.name,
        type: TransferTaskType.download,
        status: TransferTaskStatus.pending,
        progress: 0,
        target: targetDirectory,
        sourcePath: item.path,
        batchId: batchId,
        totalBytes: item.size,
      ),
      QueuedTransfer((report, isCanceled) async {
        await _sessionController.ensureSessionReady();
        if (isCanceled()) throw const TransferCanceledException();
        final mediaCollection = _androidMediaCollection(item.name);
        if (mediaCollection != null) {
          await _ossClient.downloadToMediaStore(
            item.path,
            _sessionController.requireSession(),
            displayName: item.name,
            collection: mediaCollection,
            taskId: taskId,
            onProgress: report,
            isCanceled: isCanceled,
          );
          _transferQueue.replaceTask(
              taskId, (task) => task.copyWith(target: '系统相册'));
          return;
        }
        if (targetDirectory.startsWith('content://')) {
          await _ossClient.downloadToDirectoryUri(
            item.path,
            _sessionController.requireSession(),
            directoryUri: targetDirectory,
            displayName: item.name,
            taskId: taskId,
            onProgress: report,
            isCanceled: isCanceled,
          );
          _transferQueue.replaceTask(
              taskId, (task) => task.copyWith(target: '已选目录'));
          return;
        }
        final destination =
            await _availableDownloadFile(targetDirectory, item.name);
        final temporary = File('${destination.path}.$taskId.part');
        try {
          await _ossClient.downloadToFile(
            item.path,
            _sessionController.requireSession(),
            temporary,
            taskId: taskId,
            onProgress: report,
            isCanceled: isCanceled,
          );
          if (isCanceled()) throw const TransferCanceledException();
          await temporary.rename(destination.path);
          _transferQueue.replaceTask(
              taskId, (task) => task.copyWith(target: destination.path));
        } catch (_) {
          if (await temporary.exists()) await temporary.delete();
          rethrow;
        }
      }),
    );
    return taskId;
  }

  /// 相册原图按需下载：写入相册专用缓存目录，完成后由回调写入缓存记录。
  /// 走现有传输队列，进度、取消与重试与普通下载一致。
  String enqueueOriginalDownload({
    required String path,
    required String name,
    required int? totalBytes,
    required File target,
    required Future<void> Function(File target) onCompleted,
  }) {
    if (!_sessionController.capabilities.download) {
      throw StateError('当前身份没有下载权限');
    }
    _workspaceController.ensureWithinRoot(path);
    final taskId = _transferQueue.newTransferId('download');
    _transferQueue.enqueue(
      TransferTask(
        id: taskId,
        name: name,
        type: TransferTaskType.download,
        status: TransferTaskStatus.pending,
        progress: 0,
        target: '相册缓存',
        sourcePath: path,
        totalBytes: totalBytes,
      ),
      QueuedTransfer((report, isCanceled) async {
        await _sessionController.ensureSessionReady();
        if (isCanceled()) throw const TransferCanceledException();
        final temporary = File('${target.path}.$taskId.part');
        try {
          await _ossClient.downloadToFile(
            path,
            _sessionController.requireSession(),
            temporary,
            taskId: taskId,
            onProgress: report,
            isCanceled: isCanceled,
          );
          if (isCanceled()) throw const TransferCanceledException();
          await temporary.rename(target.path);
          await onCompleted(target);
        } catch (_) {
          if (await temporary.exists()) await temporary.delete();
          rethrow;
        }
      }),
    );
    return taskId;
  }

  String enqueueDownloads(Iterable<FileItem> items,
      {required String targetDirectory}) {
    final batchId = 'batch-${DateTime.now().microsecondsSinceEpoch}';
    for (final item in items.where((item) => !item.isDirectory)) {
      enqueueDownload(item, targetDirectory: targetDirectory, batchId: batchId);
    }
    return batchId;
  }

  /// 递归展开选中的文件夹，并将每个文件作为独立下载任务入队。
  ///
  /// 目录中的文件按其相对于当前文件视图的路径保存，避免拍平目录结构。
  Future<BatchDownloadEnqueueResult> enqueueDownloadsRecursively(
    Iterable<FileItem> items, {
    required String targetDirectory,
  }) async {
    if (!_sessionController.capabilities.download) {
      throw StateError('当前身份没有下载权限');
    }
    final selected = items.toList(growable: false);
    final targets = <String, _DownloadTarget>{};
    await _sessionController.ensureSessionReady();
    final session = _sessionController.requireSession();

    for (final item in selected.where((item) => item.isDirectory)) {
      _workspaceController.ensureWithinRoot(item.path);
      final keys = await _ossClient.listAllObjectKeys(item.path, session);
      for (final key in keys.where((key) => !key.endsWith('/'))) {
        _workspaceController.ensureWithinRoot(key);
        targets.putIfAbsent(
          key,
          () => _DownloadTarget(
            item: FileItem(
              path: key,
              name: _fileName(key),
              isDirectory: false,
            ),
            targetDirectory: _downloadDirectoryFor(key, targetDirectory),
          ),
        );
      }
    }
    for (final item in selected.where((item) => !item.isDirectory)) {
      _workspaceController.ensureWithinRoot(item.path);
      targets.putIfAbsent(
        item.path,
        () => _DownloadTarget(item: item, targetDirectory: targetDirectory),
      );
    }

    final batchId = 'batch-${DateTime.now().microsecondsSinceEpoch}';
    for (final target in targets.values) {
      enqueueDownload(
        target.item,
        targetDirectory: target.targetDirectory,
        batchId: batchId,
      );
    }
    return BatchDownloadEnqueueResult(
      batchId: batchId,
      fileCount: targets.length,
      directoryCount: selected.where((item) => item.isDirectory).length,
    );
  }

  void retryTask(String taskId) {
    final task =
        _transferQueue.tasks.where((item) => item.id == taskId).firstOrNull;
    if (task == null ||
        (task.status != TransferTaskStatus.failed &&
            task.status != TransferTaskStatus.canceled)) {
      return;
    }
    _transferQueue.requestNotificationPermission();
    if (!_transferQueue.hasExecutor(taskId)) {
      // 冷启动恢复出的上传任务：按持久化字段重建执行器后正常入队。
      final dir = task.targetDir;
      final source = task.sourcePath;
      if (task.type == TransferTaskType.upload &&
          dir != null &&
          source != null &&
          source.isNotEmpty) {
        if (!File(source).existsSync()) {
          _transferQueue.replaceTask(
              taskId,
              (value) => value.copyWith(
                    status: TransferTaskStatus.failed,
                    message: '失败',
                    error: '源文件已丢失',
                  ));
          return;
        }
        _transferQueue.setExecutor(
          taskId,
          _buildUploadClosure(
            taskId: taskId,
            fileName: task.name,
            localPath: source,
            dir: dir,
            batchId: task.batchId,
          ),
        );
        _transferQueue.requeueTask(
            taskId,
            (value) => value.copyWith(
                  status: TransferTaskStatus.pending,
                  progress: 0,
                  transferredBytes: 0,
                  bytesPerSecond: null,
                  message: '重新开始',
                ));
        return;
      }
      // 兼容应用恢复前遗留或测试注入的任务；真实任务均有执行器。
      _transferQueue.replaceTask(
          taskId,
          (value) => value.copyWith(
                status: TransferTaskStatus.running,
                progress: 0,
                message: '重新开始',
              ));
      return;
    }
    _transferQueue.requeueTask(
        taskId,
        (value) => value.copyWith(
              status: TransferTaskStatus.pending,
              progress: 0,
              transferredBytes: 0,
              message: '重新开始',
            ));
  }

  /// 对已失败或已取消的任务重新排队。
  void retryTasks(Iterable<String> taskIds) {
    for (final taskId in taskIds.toSet()) {
      retryTask(taskId);
    }
  }

  /// 继续「已中断」的上传任务：复用既有上传闭包重新入队。Android 与
  /// macOS 的大文件均为分片上传并保留 checkpoint，可从已传分片续传。
  /// 源文件缺失时直接标记失败。
  void resumeInterruptedUpload(String taskId) {
    final task =
        _transferQueue.tasks.where((item) => item.id == taskId).firstOrNull;
    if (task == null ||
        task.type != TransferTaskType.upload ||
        task.status != TransferTaskStatus.interrupted) {
      return;
    }
    _transferQueue.requestNotificationPermission();
    final dir = task.targetDir;
    final source = task.sourcePath;
    if (dir == null ||
        source == null ||
        source.isEmpty ||
        !File(source).existsSync()) {
      _transferQueue.replaceTask(
          taskId,
          (value) => value.copyWith(
                status: TransferTaskStatus.failed,
                message: '失败',
                error: '源文件已丢失',
              ));
      return;
    }
    _transferQueue.setExecutor(
      taskId,
      _buildUploadClosure(
        taskId: taskId,
        fileName: task.name,
        localPath: source,
        dir: dir,
        batchId: task.batchId,
      ),
    );
    _transferQueue.requeueTask(
        taskId,
        (value) => value.copyWith(
              status: TransferTaskStatus.pending,
              progress: 0,
              transferredBytes: 0,
              bytesPerSecond: null,
              message: '重新开始',
            ));
  }

  /// 批量继续全部已中断上传任务（纯便利入口，逐个调用单任务操作）。
  void resumeAllInterruptedUploads() {
    for (final taskId in interruptedUploadTaskIds.toList(growable: false)) {
      resumeInterruptedUpload(taskId);
    }
  }

  /// 放弃「已中断」的上传任务：转已取消并清理对应 staging 文件。
  void abandonInterruptedUpload(String taskId) {
    final task =
        _transferQueue.tasks.where((item) => item.id == taskId).firstOrNull;
    if (task == null ||
        task.type != TransferTaskType.upload ||
        task.status != TransferTaskStatus.interrupted) {
      return;
    }
    final abandoned = task.copyWith(
      status: TransferTaskStatus.canceled,
      message: '已放弃',
    );
    _transferQueue.replaceTask(taskId, (value) => abandoned);
    _cleanupStagingForTask(abandoned);
  }

  /// 批量放弃全部已中断上传任务（纯便利入口，逐个调用单任务操作）。
  void abandonAllInterruptedUploads() {
    for (final taskId in interruptedUploadTaskIds.toList(growable: false)) {
      abandonInterruptedUpload(taskId);
    }
  }

  Set<String> get interruptedUploadTaskIds => _transferQueue.tasks
      .where((task) =>
          task.type == TransferTaskType.upload &&
          task.status == TransferTaskStatus.interrupted)
      .map((task) => task.id)
      .toSet();

  /// 任务不再需要时清理其 staging 源文件（判定依据：sourcePath 位于
  /// staging 目录内）；持久路径源文件不删除。
  void _cleanupStagingForTask(TransferTask task) {
    if (task.type != TransferTaskType.upload) return;
    unawaited(_uploadStaging?.cleanup(task.sourcePath));
  }

  void cancelTask(String taskId) {
    final task =
        _transferQueue.tasks.where((item) => item.id == taskId).firstOrNull;
    if (task == null ||
        (task.status != TransferTaskStatus.running &&
            task.status != TransferTaskStatus.pending)) {
      return;
    }
    _transferQueue.removePendingTask(taskId);
    _transferQueue.markCanceled(taskId);
    // 显式取消优先于暂停请求，避免运行中任务被误送回等待队列。
    _transferQueue.clearPauseRequest(taskId);
    if (task.status == TransferTaskStatus.running) {
      unawaited(_ossClient.cancelTransfer(taskId));
    }
    _transferQueue.replaceTask(
        taskId,
        (value) => value.copyWith(
              status: TransferTaskStatus.canceled,
              message: '已取消',
            ));
  }

  /// 取消正在等待或执行中的任务。
  void cancelTasks(Iterable<String> taskIds) {
    for (final taskId in taskIds.toSet()) {
      cancelTask(taskId);
    }
  }

  /// 一键暂停：停止调度等待中的任务；运行中的任务收到停止信号后回到
  /// 等待队列。上传任务（Android 与 macOS 均为分片 checkpoint）可从
  /// 已传分片续传；下载不支持断点，继续时从头下载。
  void pauseAllTransfers() {
    _transferQueue.setQueuePaused(true);
    for (final taskId in _transferQueue.runningTaskIds) {
      _transferQueue.markPauseRequested(taskId);
      _transferQueue.markCanceled(taskId);
      unawaited(_ossClient.cancelTransfer(taskId));
    }
    for (final taskId in _transferQueue.pendingTaskIds) {
      _transferQueue.replaceTask(
          taskId,
          (task) => task.copyWith(
                bytesPerSecond: null,
                message: '已暂停',
              ));
    }
  }

  /// 一键继续：解除队列暂停并立即调度等待中的任务。
  void resumeAllTransfers() {
    if (!_transferQueue.transferQueuePaused) return;
    _transferQueue.setQueuePaused(false);
    _transferQueue.drain();
  }

  /// 一键停止全部未完成任务（运行中与等待中），并解除队列暂停。
  void cancelAllTransfers() {
    _transferQueue.setQueuePaused(false);
    final taskIds = _transferQueue.tasks
        .where((task) =>
            task.status == TransferTaskStatus.running ||
            task.status == TransferTaskStatus.pending)
        .map((task) => task.id)
        .toList(growable: false);
    cancelTasks(taskIds);
  }

  void clearCompletedTasks() {
    final removed = _transferQueue.tasksListenable.value
        .where(
          (task) =>
              task.status == TransferTaskStatus.success ||
              task.status == TransferTaskStatus.canceled,
        )
        .toList(growable: false);
    // 已结束任务从列表移除后不再可重试，对应 staging 源文件一并清理。
    for (final task in removed) {
      _cleanupStagingForTask(task);
    }
    _transferQueue.setTasks(
      _transferQueue.tasksListenable.value
          .where(
            (task) =>
                task.status != TransferTaskStatus.success &&
                task.status != TransferTaskStatus.canceled,
          )
          .toList(),
    );
  }

  Future<File> _availableDownloadFile(String directory, String name) async {
    final slash = Platform.pathSeparator;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var index = 0;; index++) {
      final suffix = index == 0 ? '' : ' ($index)';
      final candidate = File('$directory$slash$base$suffix$extension');
      if (!await candidate.exists()) return candidate;
    }
  }

  String _downloadDirectoryFor(String objectPath, String targetDirectory) {
    final currentPath = _workspaceController.currentPath;
    final relative = objectPath.startsWith(currentPath)
        ? objectPath.substring(currentPath.length)
        : objectPath;
    final segments =
        relative.split('/').where((segment) => segment.isNotEmpty).toList();
    if (segments.length < 2) return targetDirectory;
    return <String>[
      targetDirectory,
      ...segments.take(segments.length - 1),
    ].join(Platform.pathSeparator);
  }

  String? _androidMediaCollection(String fileName) {
    if (!Platform.isAndroid) return null;
    final extension = fileName.split('.').last.toLowerCase();
    if (const <String>{'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'}
        .contains(extension)) {
      return 'images';
    }
    if (const <String>{'mp4', 'mov', 'mkv', 'avi', 'webm', '3gp'}
        .contains(extension)) {
      return 'video';
    }
    return null;
  }

  String _fileName(String path) {
    final normalized =
        path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }
}

class _DownloadTarget {
  const _DownloadTarget({required this.item, required this.targetDirectory});

  final FileItem item;
  final String targetDirectory;
}
