import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/transfer_keepalive.dart';
import '../../workspace/infrastructure/oss_client.dart'
    show TransferCanceledException;
import '../domain/transfer_task.dart';
import '../domain/transfer_type_counts.dart';
import '../infrastructure/transfer_history_store.dart';

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
  TransferQueue({
    required TransferKeepaliveService transferKeepalive,
    TransferHistoryStore? historyStore,
  })  : _transferKeepalive = transferKeepalive,
        _historyStore = historyStore ?? TransferHistoryStore();

  final TransferKeepaliveService _transferKeepalive;
  final TransferHistoryStore _historyStore;

  /// 上传任务到达成功终态后的清理挂钩（staging 源文件清理），
  /// 由持有方装配；失败与取消保留源文件供重试。
  void Function(TransferTask task)? onTaskSucceeded;

  static const _transferConcurrencyKey = 'transfer_concurrency';
  static const _legacyTransferHistoryKey = 'transfer_history:v1';
  static const _uploadPendingKey = 'upload_pending:v1';
  static const _minTransferConcurrency = 1;
  static const _maxTransferConcurrency = 5;
  static const historyPageSize = 300;
  static const historyRetentionDays = 90;
  static const historyMaxRecords = 20000;
  static const _historyWriteDelay = Duration(milliseconds: 300);
  static const _historyPruneInterval = Duration(hours: 1);

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

  /// 历史记录按类型计数；null 表示历史库不可用，界面回退为内存任务计数。
  final ValueNotifier<TransferTypeCounts?> historyCountsListenable =
      ValueNotifier<TransferTypeCounts?>(null);

  /// 是否仍有更旧的历史分页可加载。
  final ValueNotifier<bool> historyHasMoreListenable =
      ValueNotifier<bool>(false);

  /// 是否正在加载历史分页。
  final ValueNotifier<bool> historyLoadingListenable =
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
  bool _historyStoreReady = false;
  bool _historyLoading = false;
  bool _disposed = false;
  TransferHistoryCursor? _historyCursor;
  DateTime? _lastHistoryPruneAt;
  Timer? _historyWriteTimer;
  bool _isFlushingHistory = false;
  final Map<String, TransferTask> _pendingHistoryUpserts =
      <String, TransferTask>{};
  final Set<String> _pendingHistoryDeletes = <String>{};
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

  /// 类型筛选计数：保留范围内全部历史记录 + 内存中未结束任务。
  TransferTypeCounts get typeCounts {
    final historical = historyCountsListenable.value;
    if (historical == null || !_historyStoreReady) {
      return _countTasksByType(tasks);
    }
    var upload = historical.upload;
    var download = historical.download;
    for (final task in tasks.where((task) => !task.isFinished)) {
      if (task.type == TransferTaskType.upload) {
        upload++;
      } else {
        download++;
      }
    }
    return TransferTypeCounts(upload: upload, download: download);
  }

  bool get historyHasMore => historyHasMoreListenable.value;
  bool get historyLoading => historyLoadingListenable.value;

  // ---------- 启动恢复与偏好 ----------

  /// 启动恢复：并发设置、未完成上传记录与 SQLite 历史首页。恢复完成后
  /// 开启历史持久化写入，避免恢复阶段的历史加载触发回写。
  Future<void> restore(SharedPreferences preferences) async {
    _preferences = preferences;
    final savedConcurrency = preferences.getInt(_transferConcurrencyKey);
    if (savedConcurrency != null &&
        savedConcurrency >= _minTransferConcurrency &&
        savedConcurrency <= _maxTransferConcurrency) {
      transferConcurrencyListenable.value = savedConcurrency;
    }
    // 先恢复未完成上传，历史加载时跳过同 id 记录，避免失败上传同时
    // 出现在 upload_pending 与历史库中。
    final startupFailures = await _restoreUploadPending(preferences);
    await _restoreTransferHistory(preferences);
    _transferHistoryReady = true;
    if (startupFailures.isNotEmpty) {
      // 启动时因源文件丢失转为失败的任务没有经历运行收尾，需单独补写历史。
      if (_historyStoreReady) {
        try {
          await _historyStore.upsertAll(startupFailures);
          await _refreshHistoryCounts();
        } catch (error) {
          debugPrint('[transfer] 写入启动失败任务历史失败: $error');
        }
      }
    }
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
  void setTasks(List<TransferTask> next) => _setTasks(next);

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

  /// 主动落盘待写历史（进入后台或退出前调用），缩小应用被杀导致
  /// 最后几条记录丢失的窗口。
  Future<void> flushHistory() async {
    _historyWriteTimer?.cancel();
    _historyWriteTimer = null;
    await _flushHistoryWrites();
  }

  void dispose() {
    _historyWriteTimer?.cancel();
    _historyWriteTimer = null;
    // 先启动落盘再标记 disposed：flush 入口的同步检查可通过，关闭前
    // 尽量写完待处理历史。
    unawaited(() async {
      await _flushHistoryWrites();
      await _historyStore.close();
    }());
    _disposed = true;
    tasksListenable.dispose();
    transferConcurrencyListenable.dispose();
    transferQueuePausedListenable.dispose();
    historyCountsListenable.dispose();
    historyHasMoreListenable.dispose();
    historyLoadingListenable.dispose();
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
    final runStartedAt = DateTime.now();
    _replaceTask(
        taskId,
        (task) => task.copyWith(
              status: TransferTaskStatus.running,
              message: '进行中',
              startedAt: task.startedAt ?? runStartedAt,
              lastStartedAt: runStartedAt,
            ));
    final speedTracker = _TransferSpeedTracker();
    final stopwatch = Stopwatch()..start();
    var lastUiUpdate = Duration.zero;
    var lastReceivedBytes = 0;
    var reportedProgress = false;
    try {
      await queued.run(
        (received, total) {
          lastReceivedBytes = received;
          reportedProgress = true;
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
                  finishedAt: DateTime.now(),
                ));
      } else {
        _replaceTask(
            taskId,
            (task) => task.copyWith(
                  status: TransferTaskStatus.success,
                  progress: 1,
                  bytesPerSecond: null,
                  message: '已完成',
                  finishedAt: DateTime.now(),
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
                  finishedAt: DateTime.now(),
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
                finishedAt: DateTime.now(),
              ));
    } catch (error) {
      _replaceTask(
          taskId,
          (task) => task.copyWith(
                status: TransferTaskStatus.failed,
                message: '失败',
                error: error.toString().replaceFirst('Bad state: ', ''),
                finishedAt: DateTime.now(),
              ));
    } finally {
      stopwatch.stop();
      final elapsedMs = stopwatch.elapsedMilliseconds;
      _replaceTask(
        taskId,
        (task) => task.copyWith(
          activeDurationMs: task.activeDurationMs + elapsedMs,
          totalTransferredBytes:
              task.totalTransferredBytes + (reportedProgress ? lastReceivedBytes : 0),
        ),
      );
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
  /// 累计时长与字节在 [_runTransfer] 的 finally 中结算，暂停不清零。
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
              clearFinishedAt: true,
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

  Future<void> _restoreTransferHistory(SharedPreferences preferences) async {
    try {
      await _historyStore.open();
      _historyStoreReady = true;
    } catch (error) {
      debugPrint('[transfer] 打开传输历史库失败: $error');
      _historyStoreReady = false;
      return;
    }
    await _migrateLegacyTransferHistory(preferences);
    // 先清理保留窗口外的记录，避免首页加载到即将淘汰的数据。
    await _pruneHistory(force: true);
    try {
      final page = await _historyStore.loadPage(limit: historyPageSize);
      _appendHistoryPage(page);
    } catch (error) {
      debugPrint('[transfer] 读取传输历史失败: $error');
      historyHasMoreListenable.value = false;
    }
    await _refreshHistoryCounts();
  }

  /// 首次升级时将旧 SharedPreferences 历史一次性导入 SQLite；旧键保留
  /// 作为回滚快照且不再更新。导入标记写入数据库，重复启动不会重复导入。
  Future<void> _migrateLegacyTransferHistory(
    SharedPreferences preferences,
  ) async {
    try {
      if (await _historyStore.isMigrationDone()) return;
    } catch (_) {
      return;
    }
    final imported = <TransferTask>[];
    final raw = preferences.getString(_legacyTransferHistoryKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          imported.addAll(
            decoded
                .whereType<Map>()
                .map((item) => TransferTask.fromJson(
                      item.map((key, value) => MapEntry(key.toString(), value)),
                    ))
                .whereType<TransferTask>()
                .where(_isHistoricalTransferTask),
          );
        }
      } catch (error) {
        // 旧记录损坏时仍标记完成，避免每次启动重复解析失败。
        debugPrint('[transfer] 旧传输历史解析失败: $error');
      }
    }
    try {
      if (imported.isNotEmpty) await _historyStore.upsertAll(imported);
      await _historyStore.markMigrationDone();
    } catch (error) {
      debugPrint('[transfer] 旧传输历史导入失败: $error');
    }
  }

  /// 读取下一页历史并追加到任务表；按 id 去重，不重复加载已有记录。
  Future<void> loadMoreHistory() async {
    if (!_historyStoreReady ||
        _disposed ||
        _historyLoading ||
        !historyHasMoreListenable.value) {
      return;
    }
    _historyLoading = true;
    historyLoadingListenable.value = true;
    try {
      final page = await _historyStore.loadPage(
        limit: historyPageSize,
        after: _historyCursor,
      );
      _appendHistoryPage(page);
    } catch (error) {
      debugPrint('[transfer] 加载更多传输历史失败: $error');
      historyHasMoreListenable.value = false;
    } finally {
      _historyLoading = false;
      historyLoadingListenable.value = false;
    }
  }

  void _appendHistoryPage(List<TransferTask> page) {
    final existingIds = tasks.map((task) => task.id).toSet();
    final appended = page
        .where((task) => !existingIds.contains(task.id))
        .toList(growable: false);
    if (appended.isNotEmpty) {
      tasksListenable.value =
          List<TransferTask>.unmodifiable(<TransferTask>[...tasks, ...appended]);
    }
    if (page.isNotEmpty) {
      _historyCursor = TransferHistoryCursor.fromTask(page.last);
    }
    historyHasMoreListenable.value = page.length >= historyPageSize;
  }

  bool _isHistoricalTransferTask(TransferTask task) => task.isFinished;

  /// 对比任务表前后状态，终态任务进入待写集合，重试/移除的终态任务
  /// 进入待删集合；批量合并为单事务写入。
  void _syncHistoryWrites(
    List<TransferTask> previous,
    List<TransferTask> next,
  ) {
    if (!_transferHistoryReady || !_historyStoreReady || _disposed) return;
    final previousById = <String, TransferTask>{
      for (final task in previous) task.id: task,
    };
    final nextIds = <String>{for (final task in next) task.id};
    for (final task in next) {
      final before = previousById[task.id];
      if (task.isFinished) {
        if (before == null || !identical(before, task)) {
          _pendingHistoryUpserts[task.id] = task;
        }
      } else if (before != null && before.isFinished) {
        _pendingHistoryDeletes.add(task.id);
      }
    }
    for (final entry in previousById.entries) {
      if (!nextIds.contains(entry.key) && entry.value.isFinished) {
        _pendingHistoryDeletes.add(entry.key);
      }
    }
    if (_pendingHistoryUpserts.isEmpty && _pendingHistoryDeletes.isEmpty) {
      return;
    }
    // 删除（清除已结束、重试移出）需要及时落盘；upsert 合并短延迟。
    _scheduleHistoryWrite(immediate: _pendingHistoryDeletes.isNotEmpty);
  }

  void _scheduleHistoryWrite({bool immediate = false}) {
    if (immediate) {
      _historyWriteTimer?.cancel();
      _historyWriteTimer = null;
      unawaited(_flushHistoryWrites());
      return;
    }
    _historyWriteTimer ??= Timer(_historyWriteDelay, () {
      _historyWriteTimer = null;
      unawaited(_flushHistoryWrites());
    });
  }

  Future<void> _flushHistoryWrites() async {
    if (!_historyStoreReady || _disposed) return;
    if (_isFlushingHistory) return;
    if (_pendingHistoryUpserts.isEmpty && _pendingHistoryDeletes.isEmpty) {
      return;
    }
    _isFlushingHistory = true;
    try {
      while (_pendingHistoryUpserts.isNotEmpty ||
          _pendingHistoryDeletes.isNotEmpty) {
        final deletes = _pendingHistoryDeletes.toList(growable: false);
        _pendingHistoryDeletes.clear();
        final upserts = _pendingHistoryUpserts.values.toList(growable: false);
        _pendingHistoryUpserts.clear();
        try {
          if (deletes.isNotEmpty) await _historyStore.deleteIds(deletes);
          if (upserts.isNotEmpty) await _historyStore.upsertAll(upserts);
        } catch (error) {
          // 写入失败时放回待写集合，下次触发重试；不阻断传输。
          debugPrint('[transfer] 写入传输历史失败: $error');
          _pendingHistoryDeletes.addAll(deletes);
          for (final task in upserts) {
            _pendingHistoryUpserts[task.id] = task;
          }
          break;
        }
        await _refreshHistoryCounts();
        await _pruneHistory();
      }
    } finally {
      _isFlushingHistory = false;
      if (!_disposed &&
          (_pendingHistoryUpserts.isNotEmpty ||
              _pendingHistoryDeletes.isNotEmpty)) {
        _scheduleHistoryWrite();
      }
    }
  }

  Future<void> _refreshHistoryCounts() async {
    if (!_historyStoreReady || _disposed) return;
    try {
      final counts = await _historyStore.countByType();
      if (_disposed) return;
      historyCountsListenable.value = TransferTypeCounts(
        upload: counts[TransferTaskType.upload] ?? 0,
        download: counts[TransferTaskType.download] ?? 0,
      );
    } catch (error) {
      debugPrint('[transfer] 统计传输历史失败: $error');
    }
  }

  Future<void> _pruneHistory({bool force = false}) async {
    if (!_historyStoreReady) return;
    final now = DateTime.now();
    final last = _lastHistoryPruneAt;
    if (!force && last != null && now.difference(last) < _historyPruneInterval) {
      return;
    }
    _lastHistoryPruneAt = now;
    try {
      await _historyStore.prune(
        cutoff: now.subtract(const Duration(days: historyRetentionDays)),
        maxRecords: historyMaxRecords,
      );
    } catch (error) {
      debugPrint('[transfer] 清理传输历史失败: $error');
    }
  }

  TransferTypeCounts _countTasksByType(List<TransferTask> source) {
    var upload = 0;
    var download = 0;
    for (final task in source) {
      if (task.type == TransferTaskType.upload) {
        upload++;
      } else {
        download++;
      }
    }
    return TransferTypeCounts(upload: upload, download: download);
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
  /// 恢复不自动入队，不阻塞应用启动。返回本次转为失败的终态任务，
  /// 供恢复完成后补写历史。
  Future<List<TransferTask>> _restoreUploadPending(
    SharedPreferences preferences,
  ) async {
    final raw = preferences.getString(_uploadPendingKey);
    if (raw == null || raw.isEmpty) return const <TransferTask>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <TransferTask>[];
      final records = decoded
          .whereType<Map>()
          .map((item) => TransferTask.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
              ))
          .whereType<TransferTask>()
          .where(_isPersistentUploadTask)
          .toList(growable: false);
      if (records.isEmpty) return const <TransferTask>[];
      final exists = await Future.wait<bool>(records.map((task) {
        final source = task.sourcePath;
        if (source == null || source.isEmpty) {
          return Future<bool>.value(false);
        }
        return File(source).exists();
      }));
      final restored = <TransferTask>[];
      final failures = <TransferTask>[];
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
          final failed = task.copyWith(
            status: TransferTaskStatus.failed,
            message: '失败',
            error: '源文件已丢失',
            finishedAt: DateTime.now(),
          );
          restored.add(failed);
          failures.add(failed);
        }
      }
      tasksListenable.value = List<TransferTask>.unmodifiable([
        ...tasksListenable.value,
        ...restored,
      ]);
      return failures;
    } catch (_) {
      // 本地记录损坏时忽略，避免影响应用启动。
      return const <TransferTask>[];
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
    final previous = tasksListenable.value;
    tasksListenable.value = List<TransferTask>.unmodifiable(next);
    _syncHistoryWrites(previous, next);
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
