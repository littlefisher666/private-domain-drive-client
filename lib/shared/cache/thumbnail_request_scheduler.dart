import 'dart:async';

import 'package:flutter/foundation.dart';

typedef ThumbnailTask = Future<List<int>?> Function();

/// 缩略图请求调度器：全局并发上限、同键去重、后进先出分发、
/// 取消尚未开始分发的作业。
///
/// - 同键并发请求共享同一作业与结果，结果由调用方各自消费；
/// - 队列取最新入队的作业，使快速滚动时当前屏幕的请求优先；
/// - [cancel] 只对尚未开始分发的作业生效：取消后该作业不再执行，
///   其 Future 以 `null` 完成；已在途的请求允许完成（无法中断原生
///   请求，完成后写入磁盘缓存供回访命中）。
class ThumbnailRequestScheduler {
  ThumbnailRequestScheduler({required this.maxConcurrency})
      : assert(maxConcurrency > 0);

  final int maxConcurrency;

  final Map<String, _ScheduledThumbnailJob> _jobs =
      <String, _ScheduledThumbnailJob>{};
  final List<_ScheduledThumbnailJob> _queue = <_ScheduledThumbnailJob>[];
  int _inFlight = 0;

  /// 当前在途作业数。
  int get inFlight => _inFlight;

  /// 当前排队等待分发的作业数。
  int get pending => _queue.length;

  /// 提交缩略图作业；同一 [key] 的在途/排队作业被复用。
  Future<List<int>?> run(String key, ThumbnailTask task) {
    final existing = _jobs[key];
    if (existing != null) {
      existing.subscribers++;
      return existing.completer.future;
    }
    final job = _ScheduledThumbnailJob(key: key, task: task);
    _jobs[key] = job;
    _queue.add(job);
    _pump();
    return job.completer.future;
  }

  /// 取消某个键对应的排队作业。仅当没有其他订阅者且作业尚未开始时
  /// 生效。
  void cancel(String key) {
    final job = _jobs[key];
    if (job == null) return;
    job.subscribers--;
    if (job.started || job.subscribers > 0) return;
    _queue.remove(job);
    _jobs.remove(key);
    if (!job.completer.isCompleted) {
      debugPrint('[gallery] 取消排队缩略图请求 $key');
      job.completer.complete(null);
    }
  }

  void _pump() {
    while (_inFlight < maxConcurrency && _queue.isNotEmpty) {
      final job = _queue.removeLast();
      job.started = true;
      _inFlight++;
      job.task().then(
        (value) => _finish(job, value),
        onError: (Object error, StackTrace stack) {
          debugPrint('[gallery] 缩略图调度任务异常 ${job.key}: $error');
          _finish(job, null);
        },
      );
    }
  }

  void _finish(_ScheduledThumbnailJob job, List<int>? value) {
    _inFlight--;
    _jobs.remove(job.key);
    if (!job.completer.isCompleted) {
      job.completer.complete(value);
    }
    _pump();
  }
}

class _ScheduledThumbnailJob {
  _ScheduledThumbnailJob({required this.key, required this.task});

  final String key;
  final ThumbnailTask task;
  final Completer<List<int>?> completer = Completer<List<int>?>();
  int subscribers = 1;
  bool started = false;
}