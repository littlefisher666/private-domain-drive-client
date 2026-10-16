import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/transfer_keepalive.dart';
import '../../workspace/infrastructure/oss_client.dart'
    show TransferCanceledException;
import '../domain/transfer_task.dart';

/// 单次传输进度上报：已接收字节数与可选总字节数。
typedef TransferProgressReporter = void Function(int received, int? total);

/// 队列内任务的可执行闭包：进度上报与取消判定回调由队列在调度时注入。
class QueuedTransfer {
  const QueuedTransfer(this.run);

  final Future<void> Function(
    TransferProgressReporter report,
    bool Function() isCanceled,
  ) run;
}

/// 任务因「已存在，跳过」而未发起上传时抛出，由传输队列标记为完成。
class UploadSkippedException implements Exception {
  const UploadSkippedException();
}

/// 传输队列：持有任务表与等待/运行/取消/暂停集合，承载队列调度、
/// 保活通知同步，以及传输历史与未完成上传的本地持久化。
/// 非 [ChangeNotifier]：任务表与并发/暂停状态经细粒度 [ValueNotifier]
/// 对外通知，避免传输进度刷新整个应用外壳。
class TransferQueue {
  TransferQueue({required TransferKeepaliveService transferKeepalive})
      : _transferKeepalive = transferKeepalive;

  final TransferKeepaliveService _transferKeepalive;

  /// 上传任务到达成功终态后的清理挂钩（staging 源文件清理），
  /// 由持有方装配；失败与取消保留源文件供重试。
  void Function(TransferTask task)? onTaskSucceeded;

  static const _transferConcurrencyKey = 'transfer_concurrency';
  static const _transferHistoryKey = 'transfer_history:v1';
  static const _uploadPendingKey = 'upload_pending:v1';
  static const _minTransferConcurrency = 1;
  static const _maxTransferConcurrency = 5;

  /// Transfer task list/progress updates only; does not rebuild workspace.
  final ValueNotifier<List<TransferTask>> tasksListenable =
      ValueNotifier<List<TransferTask>>(<TransferTask>[]);

  /// 总并发数单独通知，避免传输进度刷新整个设置区域。
  final ValueNotifier<int> transferConcurrencyListenable =
      ValueNotifier<int>(3);

  /// 队列级暂停开关：暂停时不再从等待队列拉起新任务，运行中任务收到
  /// 停止信号后回到等待队列，随 resumeAllTransfers 重新调度。
  final ValueNotifier<bool> transferQueuePausedListenable =
      ValueNotifier<bool>(false);

  final List<String> _pendingTransferIds = <String>[];
  final Set<String> _runningTransferIds = <String>{};
  final Map<String, QueuedTransfer> _queuedTransfers =
      <String, QueuedTransfer>{};
  final Set<String> _canceledTransferIds = <String>{};
  final Set<String> _pauseRequestedTransferIds = <String>{};
  int _nextTransferId = 0;
  SharedPreferences? _preferences;
  bool _transferHistoryReady = false;
  bool _isSavingTransferHistory = false;
  bool _transferHistoryDirty = false;
  bool _isSavingUploadPending = false;
  bool _uploadPendingDirty = false;

  /// 最近一次写入 `upload_pending:v1` 的任务状态签名（id:status 集合）。
  /// 上传进度回调只改进度不改状态，签名不变即可跳过整表重写。
  Set<String> _uploadPendingSignature = <String>{};

  /// 签名是否与磁盘记录对齐；bootstrap 后首次写入前为 false，
  /// 保证「记录被清空到零」这类集合不变的场景也会回写一次。
  bool _uploadPendingSignatureAligned = false;

  /// 队列活跃状态与进度摘要推送给传输保活适配层（仅 Android 生效）：
  /// 活跃 = 进行中或等待中任务非空；空闲期间不再重复推送。
  /// 批次计数器：从空闲转活跃开始累计本批任务总数，任务到达终态后
  /// 累计已完成数，供通知展示「已完成 X/N」。
  bool _transferKeepaliveActive = false;
  bool _keepalivePermissionRequested = false;
  int _keepaliveBatchTotal = 0;
  int _keepaliveBatchCompleted = 0;

  // ---------- 状态读取 ----------

  List<TransferTask> get tasks => tasksListenable.value;
  int get transferConcurrency => transferConcurrencyListenable.value;
  bool get transferQueuePaused => transferQueuePausedListenable.value;
  int get runningTransferCount => _runningTransferIds.length;
  int get pendingTransferCount => _pendingTransferIds.length;

  /// 运行中与等待中任务 id 的快照，供任务操作层遍历。
  List<String> get runningTaskIds =>
      List<String>.unmodifiable(_runningTransferIds);
  List<String> get pendingTaskIds =>
      List<String>.unmodifiable(_pendingTransferIds);

  // ---------- 启动恢复与偏好 ----------

  /// 启动恢复：并发设置、传输历史与未完成上传记录。恢复完成后开启
  /// 历史持久化写入，避免恢复阶段的整表替换回写磁盘。
  Future<void> restore(SharedPreferences preferences) async {
    _preferences = preferences;
    final savedConcurrency = preferences.getInt(_transferConcurrencyKey);
    if (savedConcurrency != null &&
        savedConcurrency >= _minTransferConcurrency &&
        savedConcurrency <= _maxTransferConcurrency) {
      transferConcurrencyListenable.value = savedConcurrency;
    }
    _restoreTransferHistory(preferences);
    await _restoreUploadPending(preferences);
    _transferHistoryReady = true;
    _saveUploadPending();
  }

  Future<void> setTransferConcurrency(int value) async {
    final normalized = value.clamp(
      _minTransferConcurrency,
      _maxTransferConcurrency,
    );
    if (normalized == transferConcurrency) return;
    transferConcurrencyListenable.value = normalized;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(_transferConcurrencyKey, normalized);
    } catch (_) {
      // 设置立即生效；偏好写入失败时不阻断当前传输。
    }
    _drainTransferQueue();
  }

  // ---------- 队列调度 ----------

  String newTransferId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_nextTransferId++}';

  /// 新任务入队：注册执行闭包、写入任务表并加入等待队列立即调度。
  void enqueue(TransferTask task, QueuedTransfer transfer) {
    requestNotificationPermission();
    _queuedTransfers[task.id] = transfer;
    _setTasks(<TransferTask>[...tasks, task]);
    _pendingTransferIds.add(task.id);
    _drainTransferQueue();
  }

  /// 将任务以 [transform] 后的状态重新放回等待队列：清除取消标记、
  /// 更新任务状态并立即调度；执行器由重试/续传路径按需先经
  /// [setExecutor] 注册。
  void requeueTask(
    String taskId,
    TransferTask Function(TransferTask task) transform,
  ) {
    _canceledTransferIds.remove(taskId);
    _replaceTask(taskId, transform);
    _pendingTransferIds.add(taskId);
    _drainTransferQueue();
  }

  void replaceTask(
    String taskId,
    TransferTask Function(TransferTask task) transform,
  ) {
    final current = List<TransferTask>.from(tasks);
    final index = current.indexWhere((task) => task.id == taskId);
    if (index < 0) return;
    current[index] = transform(current[index]);
    _setTasks(current);
  }

  /// 整表替换任务（含持久化与保活同步），供清空已完成任务等批量操作使用。
  void setTasks(List<TransferTask> next) {
    tasksListenable.value = List<TransferTask>.unmodifiable(next);
    _saveTransferHistory();
    _saveUploadPending();
    _syncTransferKeepalive();
  }

  /// 从等待队列拉起任务直到达到并发上限；队列暂停时不调度。
  void drain() {
    _drainTransferQueue();
  }

  // ---------- 队列状态原语（供任务操作层使用） ----------

  bool hasExecutor(String taskId) => _queuedTransfers.containsKey(taskId);

  void setExecutor(String taskId, QueuedTransfer transfer) {
    _queuedTransfers[taskId] = transfer;
  }

  void removePendingTask(String taskId) {
    _pendingTransferIds.remove(taskId);
  }

  void clearPendingTasks() {
    _pendingTransferIds.clear();
  }

  void markCanceled(String taskId) {
    _canceledTransferIds.add(taskId);
  }

  /// 标记全部运行中任务为取消（不等待执行器自行退出）。
  void markRunningCanceled() {
    _canceledTransferIds.addAll(_runningTransferIds);
  }

  void markPauseRequested(String taskId) {
    _pauseRequestedTransferIds.add(taskId);
  }

  void clearPauseRequest(String taskId) {
    _pauseRequestedTransferIds.remove(taskId);
  }

  void clearPauseRequests() {
    _pauseRequestedTransferIds.clear();
  }

  void setQueuePaused(bool value) {
    transferQueuePausedListenable.value = value;
  }

  /// Android 13+ 首次发起传输前请求通知权限；每个应用会话仅调用一次，
  /// 拒绝授权不影响传输与前台服务。
  void requestNotificationPermission() {
    if (_keepalivePermissionRequested) return;
    _keepalivePermissionRequested = true;
    unawaited(_transferKeepalive.requestNotificationPermissionIfNeeded());
  }

  void dispose() {
    tasksListenable.dispose();
    transferConcurrencyListenable.dispose();
  }

  // ---------- 调度的内部实现 ----------

  void _drainTransferQueue() {
    if (transferQueuePausedListenable.value) return;
    while (_runningTransferIds.length < transferConcurrency &&
        _pendingTransferIds.isNotEmpty) {
      final taskId = _pendingTransferIds.removeAt(0);
      final task = tasks.where((item) => item.id == taskId).firstOrNull;
      if (task == null || task.status != TransferTaskStatus.pending) continue;
      _runningTransferIds.add(taskId);
      unawaited(_runTransfer(taskId));
    }
  }

  Future<void> _runTransfer(String taskId) async {
    final queued = _queuedTransfers[taskId];
    if (queued == null) return;
    _replaceTask(
        taskId,
        (task) => task.copyWith(
              status: TransferTaskStatus.running,
              message: '进行中',
            ));
    final speedTracker = _TransferSpeedTracker();
    var lastUiUpdate = Duration.zero;
    try {
      await queued.run(
        (received, total) {
          final now = speedTracker.elapsed;
          final isFinalBytes = total != null && total > 0 && received >= total;
          final speed = speedTracker.update(received);
          if (!isFinalBytes &&
              now - lastUiUpdate < const Duration(milliseconds: 100)) {
            return;
          }
          lastUiUpdate = now;
          final progress = total == null || total == 0
              ? 0.0
              : (received / total).clamp(0.0, 1.0);
          _replaceTask(
              taskId,
              (task) => task.copyWith(
                    progress: progress,
                    transferredBytes: received,
                    totalBytes: total,
                    bytesPerSecond: speed,
                    message: isFinalBytes ? '正在确认' : '进行中',
                  ));
        },
        () => _canceledTransferIds.contains(taskId),
      );
      if (_pauseRequestedTransferIds.remove(taskId)) {
        _returnRunningTransferToPending(taskId);
      } else if (_canceledTransferIds.contains(taskId)) {
        _replaceTask(
            taskId,
            (task) => task.copyWith(
                  status: TransferTaskStatus.canceled,
                  message: '已取消',
                ));
      } else {
        _replaceTask(
            taskId,
            (task) => task.copyWith(
                  status: TransferTaskStatus.success,
                  progress: 1,
                  bytesPerSecond: null,
                  message: '已完成',
                ));
      }
    } on TransferCanceledException {
      if (_pauseRequestedTransferIds.remove(taskId)) {
        _returnRunningTransferToPending(taskId);
      } else {
        _replaceTask(
            taskId,
            (task) => task.copyWith(
                  status: TransferTaskStatus.canceled,
                  message: '已取消',
                ));
      }
    } on UploadSkippedException {
      _replaceTask(
          taskId,
          (task) => task.copyWith(
                status: TransferTaskStatus.success,
                progress: 1,
                bytesPerSecond: null,
                message: '已存在，跳过',
              ));
    } catch (error) {
      _replaceTask(
          taskId,
          (task) => task.copyWith(
                status: TransferTaskStatus.failed,
                message: '失败',
                error: error.toString().replaceFirst('Bad state: ', ''),
              ));
    } finally {
      _runningTransferIds.remove(taskId);
      _canceledTransferIds.remove(taskId);
      // 上传任务到达成功终态后清理 staging 源文件；失败与取消保留源文件
      // 供重试，任务从列表移除时再清理。
      final finished = tasks.where((item) => item.id == taskId).firstOrNull;
      if (finished != null && finished.status == TransferTaskStatus.success) {
        onTaskSucceeded?.call(finished);
      }
      _drainTransferQueue();
      // 终态任务已从运行集移除，但对应的 _replaceTask 先于此发生，
      // 需补一次保活推送让最后一个任务结束后能转回空闲。
      _syncTransferKeepalive();
    }
  }

  /// 暂停信号触发的任务收尾：回到等待队列并重置进度，等待继续调度。
  void _returnRunningTransferToPending(String taskId) {
    _pendingTransferIds.add(taskId);
    _replaceTask(
        taskId,
        (task) => task.copyWith(
              status: TransferTaskStatus.pending,
              progress: 0,
              transferredBytes: 0,
              bytesPerSecond: null,
              message: '已暂停',
            ));
  }

  // ---------- 保活同步 ----------

  void _syncTransferKeepalive() {
    final active =
        _runningTransferIds.isNotEmpty || _pendingTransferIds.isNotEmpty;
    if (!active && !_transferKeepaliveActive) return;
    final remaining = _runningTransferIds.length + _pendingTransferIds.length;
    if (active) {
      if (!_transferKeepaliveActive) {
        _keepaliveBatchTotal = 0;
        _keepaliveBatchCompleted = 0;
      }
      final settled = _keepaliveBatchTotal - _keepaliveBatchCompleted;
      if (remaining > settled) {
        _keepaliveBatchTotal += remaining - settled;
      } else if (remaining < settled) {
        _keepaliveBatchCompleted += settled - remaining;
      }
    } else {
      _keepaliveBatchTotal = 0;
      _keepaliveBatchCompleted = 0;
    }
    _transferKeepaliveActive = active;
    unawaited(_transferKeepalive.sync(
      active: active,
      summary: active ? _transferProgressSummary(remaining) : null,
    ));
  }

  /// 进度摘要复用传输中心统计口径：剩余任务数（进行中 + 等待中）、
  /// 批次已完成/总任务数，百分比为本批次按文件数计的完成比例。
  TransferProgressSummary _transferProgressSummary(int remaining) {
    final total = _keepaliveBatchTotal;
    final completed = _keepaliveBatchCompleted.clamp(0, total);
    final percent = total > 0 ? (completed / total * 100).round().clamp(0, 100) : 0;
    return TransferProgressSummary(
      remainingCount: remaining,
      completedCount: completed,
      totalCount: total,
      percent: percent,
    );
  }

  // ---------- 传输历史持久化 ----------

  void _restoreTransferHistory(SharedPreferences preferences) {
    final rawHistory = preferences.getString(_transferHistoryKey);
    if (rawHistory == null) return;
    try {
      final decoded = jsonDecode(rawHistory);
      if (decoded is! List) return;
      final history = decoded
          .whereType<Map>()
          .map((item) => TransferTask.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
              ))
          .whereType<TransferTask>()
          .where(_isHistoricalTransferTask)
          .toList(growable: false);
      tasksListenable.value = List<TransferTask>.unmodifiable(history);
    } catch (_) {
      // 本地历史损坏时忽略，避免影响应用启动。
    }
  }

  bool _isHistoricalTransferTask(TransferTask task) {
    return task.status == TransferTaskStatus.success ||
        task.status == TransferTaskStatus.canceled;
  }

  void _saveTransferHistory() {
    if (!_transferHistoryReady) return;
    _transferHistoryDirty = true;
    if (_isSavingTransferHistory) return;
    _isSavingTransferHistory = true;
    unawaited(_persistTransferHistory());
  }

  Future<void> _persistTransferHistory() async {
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      while (_transferHistoryDirty) {
        _transferHistoryDirty = false;
        final history = tasks.where(_isHistoricalTransferTask).toList();
        await preferences.setString(
          _transferHistoryKey,
          jsonEncode(history.map((task) => task.toJson()).toList()),
        );
      }
    } catch (_) {
      // 历史记录写入失败不影响当前传输。
    } finally {
      _isSavingTransferHistory = false;
      if (_transferHistoryDirty) _saveTransferHistory();
    }
  }

  // ---------- 未完成上传持久化 ----------

  /// 未完成上传任务是否需要进入 `upload_pending:v1` 持久化记录。
  /// 失败任务保留在记录中以便重启后恢复或重试（见 upload-persistence 规格）；
  /// 源文件已缺失的失败任务（恢复时标记）不保留，其记录随之清理。
  bool _isPersistentUploadTask(TransferTask task) {
    if (task.type != TransferTaskType.upload) return false;
    return switch (task.status) {
      TransferTaskStatus.pending ||
      TransferTaskStatus.running ||
      TransferTaskStatus.interrupted =>
        true,
      TransferTaskStatus.failed => _uploadSourceExists(task),
      TransferTaskStatus.success || TransferTaskStatus.canceled => false,
    };
  }

  bool _uploadSourceExists(TransferTask task) {
    final source = task.sourcePath;
    if (source == null || source.isEmpty) return false;
    return File(source).existsSync();
  }

  /// 任务状态签名（id:status 集合）发生变化才整表重写持久化记录；
  /// 上传进度回调只更新进度字段，不会触发写入（见设计 D7）。
  void _saveUploadPending() {
    if (!_transferHistoryReady) return;
    final signature = <String>{
      for (final task in tasks.where(_isPersistentUploadTask))
        '${task.id}:${task.status.name}',
    };
    if (_uploadPendingSignatureAligned &&
        _sameStringSet(signature, _uploadPendingSignature)) {
      return;
    }
    _uploadPendingSignature = signature;
    _uploadPendingSignatureAligned = true;
    _uploadPendingDirty = true;
    if (_isSavingUploadPending) return;
    _isSavingUploadPending = true;
    unawaited(_persistUploadPending());
  }

  static bool _sameStringSet(Set<String> a, Set<String> b) {
    return a.length == b.length && a.containsAll(b);
  }

  Future<void> _persistUploadPending() async {
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      while (_uploadPendingDirty) {
        _uploadPendingDirty = false;
        final pending = tasks.where(_isPersistentUploadTask).toList();
        await preferences.setString(
          _uploadPendingKey,
          jsonEncode(pending.map((task) => task.toJson()).toList()),
        );
      }
    } catch (_) {
      // 未完成任务记录写入失败不影响当前传输。
    } finally {
      _isSavingUploadPending = false;
      if (_uploadPendingDirty) _saveUploadPending();
    }
  }

  /// 冷启动恢复未完成上传任务：源文件存在 → interrupted 等待用户操作；
  /// 源文件缺失 → failed（源文件已丢失）并从持久化记录清理。
  /// 恢复不自动入队，不阻塞应用启动。
  Future<void> _restoreUploadPending(SharedPreferences preferences) async {
    final raw = preferences.getString(_uploadPendingKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final records = decoded
          .whereType<Map>()
          .map((item) => TransferTask.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
              ))
          .whereType<TransferTask>()
          .where(_isPersistentUploadTask)
          .toList(growable: false);
      if (records.isEmpty) return;
      final exists = await Future.wait<bool>(records.map((task) {
        final source = task.sourcePath;
        if (source == null || source.isEmpty) {
          return Future<bool>.value(false);
        }
        return File(source).exists();
      }));
      final restored = <TransferTask>[];
      for (var index = 0; index < records.length; index++) {
        final task = records[index];
        if (exists[index]) {
          restored.add(task.copyWith(
            status: TransferTaskStatus.interrupted,
            progress: 0,
            transferredBytes: 0,
            bytesPerSecond: null,
            message: '已中断',
            error: null,
          ));
        } else {
          restored.add(task.copyWith(
            status: TransferTaskStatus.failed,
            message: '失败',
            error: '源文件已丢失',
          ));
        }
      }
      tasksListenable.value = List<TransferTask>.unmodifiable([
        ...tasksListenable.value,
        ...restored,
      ]);
    } catch (_) {
      // 本地记录损坏时忽略，避免影响应用启动。
    }
  }

  void _replaceTask(
    String taskId,
    TransferTask Function(TransferTask task) transform,
  ) {
    final current = List<TransferTask>.from(tasks);
    final index = current.indexWhere((task) => task.id == taskId);
    if (index < 0) return;
    current[index] = transform(current[index]);
    _setTasks(current);
  }

  void _setTasks(List<TransferTask> next) {
    tasksListenable.value = List<TransferTask>.unmodifiable(next);
    _saveTransferHistory();
    _saveUploadPending();
    _syncTransferKeepalive();
  }
}

class _TransferSpeedTracker {
  final Stopwatch _watch = Stopwatch()..start();
  final List<(Duration, int)> _samples = <(Duration, int)>[];
  double? _previousSpeed;

  Duration get elapsed => _watch.elapsed;

  double? update(int bytes) {
    final now = _watch.elapsed;
    _samples.add((now, bytes));
    final cutoff = now - const Duration(seconds: 2);
    while (_samples.length > 2 && _samples[1].$1 < cutoff) {
      _samples.removeAt(0);
    }
    final first = _samples.first;
    final elapsedMicros = (now - first.$1).inMicroseconds;
    if (elapsedMicros < const Duration(milliseconds: 100).inMicroseconds) {
      return _previousSpeed;
    }
    final delta = bytes - first.$2;
    if (delta < 0) return _previousSpeed;
    final speed = delta * Duration.microsecondsPerSecond / elapsedMicros;
    _previousSpeed = speed;
    return speed;
  }
}
