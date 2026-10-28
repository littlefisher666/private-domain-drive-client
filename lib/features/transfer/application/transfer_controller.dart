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

part 'transfer_controller_uploads.dart';
part 'transfer_controller_downloads.dart';

typedef _UploadConflictDecision
    = ({UploadConflictResolution resolution, bool applyToBatch});

/// 传输任务控制器：上传/下载任务入队与执行闭包、上传冲突处置、
/// 重试/续传/取消/暂停与已完成任务清理。任务表与队列调度由
/// [TransferQueue] 持有，本控制器只承载任务级操作。
///
/// Dart 不允许把同一个类拆到多个 part 文件，因此上传闭环与下载入队
/// 两大方法组分别以 mixin 形式放在 `transfer_controller_uploads.dart`
/// 与 `transfer_controller_downloads.dart` 中，由 [TransferController]
/// 混入；各 part 需要的控制器私有字段以抽象 getter 声明，由本类字段
/// 具体实现，公开 API 与方法签名完全不变。
class TransferController extends ChangeNotifier
    with _TransferUploads, _TransferDownloads {
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

  @override
  final SessionController _sessionController;
  @override
  final WorkspaceController _workspaceController;
  @override
  final TransferQueue _transferQueue;
  @override
  final OssClient _ossClient;
  @override
  final UploadStaging? _uploadStaging;

  /// 全局 Navigator Key，供传输队列内弹出上传冲突处置对话框。
  @override
  GlobalKey<NavigatorState>? _navigatorKey;
  @override
  GalleryIndexHooks? _galleryHooks;

  /// 批次级「整批应用」决策；同批其余已存在任务直接复用。
  @override
  final Map<String, UploadConflictResolution> _batchConflictResolutions =
      <String, UploadConflictResolution>{};

  /// 正在等待批次决策的任务共享同一个 Completer，保证一批只弹一次对话框。
  @override
  final Map<String, Completer<_UploadConflictDecision?>>
      _batchConflictWaiters = <String, Completer<_UploadConflictDecision?>>{};

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
        queuedAt: DateTime.now(),
        attemptCount: 1,
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
                    attemptCount: value.attemptCount + 1,
                    finishedAt: DateTime.now(),
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
                  attemptCount: value.attemptCount + 1,
                  clearFinishedAt: true,
                ));
        return;
      }
      // 兼容应用恢复前遗留或测试注入的任务；真实任务均有执行器。
      final now = DateTime.now();
      _transferQueue.replaceTask(
          taskId,
          (value) => value.copyWith(
                status: TransferTaskStatus.running,
                progress: 0,
                message: '重新开始',
                attemptCount: value.attemptCount + 1,
                startedAt: value.startedAt ?? now,
                lastStartedAt: now,
                clearFinishedAt: true,
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
              attemptCount: value.attemptCount + 1,
              clearFinishedAt: true,
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
                finishedAt: DateTime.now(),
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
              clearFinishedAt: true,
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
      finishedAt: DateTime.now(),
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
              finishedAt: DateTime.now(),
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
        .where((task) => task.isFinished)
        .toList(growable: false);
    // 已结束任务从列表移除后不再可重试，对应 staging 源文件一并清理，
    // 历史库中的终态记录由队列按 id 删除。
    for (final task in removed) {
      _cleanupStagingForTask(task);
    }
    _transferQueue.setTasks(
      _transferQueue.tasksListenable.value
          .where((task) => !task.isFinished)
          .toList(),
    );
  }
}
