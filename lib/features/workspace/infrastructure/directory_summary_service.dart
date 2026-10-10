import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../auth/domain/user_session.dart';
import 'directory_summary_cache.dart';
import 'oss_client.dart';

/// 子文件夹统计的编排层：本地缓存 + 受限并发后台统计 + 写时增量修正。
///
/// 统计请求受限并发（上限 4）逐个执行，单个结果先写缓存再回调；
/// 目录切换时调用方递增 generation，过期结果回调被丢弃（不中断
/// 已在途的 OSS 请求）。
class DirectorySummaryService {
  DirectorySummaryService({
    required OssClient ossClient,
    required UserSession? Function() sessionProvider,
    DirectorySummaryCache? cache,
  })  : _ossClient = ossClient,
        _sessionProvider = sessionProvider,
        _cache = cache ?? DirectorySummaryCache();

  static const int _maxConcurrency = 4;

  final OssClient _ossClient;
  final UserSession? Function() _sessionProvider;
  final DirectorySummaryCache _cache;

  /// 会话切换（登录/登出）后递增，丢弃旧会话期间在途统计的回调。
  int _generation = 0;

  String? _accountKeyOf(UserSession session) {
    final bucket = session.ossConfig?.bucket;
    if (bucket == null || bucket.isEmpty) return null;
    return '$bucket|${session.userId}';
  }

  /// 目录切换时由调用方调用，使旧目录在途统计结果不再回调。
  void bumpGeneration() => _generation++;

  /// 读取本地缓存命中的统计；缓存不可用或未命中返回 null。
  Future<DirectorySummary?> cached(String path) async {
    final session = _sessionProvider();
    if (session == null || !session.isRemote) return null;
    final accountKey = _accountKeyOf(session);
    if (accountKey == null) return null;
    final cached = await _cache.read(<String>[path], accountKey: accountKey);
    return cached[path];
  }

  /// 读取多个目录的缓存命中统计，key 为目录路径。
  Future<Map<String, DirectorySummary>> cachedAll(
    Iterable<String> paths,
  ) async {
    final session = _sessionProvider();
    if (session == null || !session.isRemote) {
      return const <String, DirectorySummary>{};
    }
    final accountKey = _accountKeyOf(session);
    if (accountKey == null) return const <String, DirectorySummary>{};
    return _cache.read(paths, accountKey: accountKey);
  }

  /// 后台统计给定目录并逐个回调；结果先写缓存。调用期间发生目录切换
  /// （generation 递增）后，剩余结果不再回调，但缓存仍会更新。
  Future<void> refresh(
    Iterable<String> paths,
    void Function(String path, DirectorySummary summary) onResult,
  ) async {
    final session = _sessionProvider();
    if (session == null || !session.isRemote) return;
    final accountKey = _accountKeyOf(session);
    if (accountKey == null) return;
    final generation = _generation;
    final queue = paths.toSet().toList(growable: false);
    if (queue.isEmpty) return;
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < queue.length) {
        final path = queue[cursor++];
        try {
          final summary = await _ossClient.directorySummary(path, session);
          await _cache.write(path, summary, accountKey: accountKey);
          if (generation == _generation) {
            onResult(path, summary);
          }
        } catch (_) {
          // 单个文件夹统计失败不影响其他文件夹，界面保持占位。
        }
      }
    }
    await Future.wait(
      List.generate(
        queue.length < _maxConcurrency ? queue.length : _maxConcurrency,
        (_) => worker(),
      ),
    );
  }

  /// 写时修正：目录内新增条目（含新建文件夹），计数增加、更新时间取操作时间。
  void noteFilesAdded(String dir, int count, DateTime at) {
    unawaited(_adjust(dir, count, at));
  }

  /// 写时修正：目录内删除条目，计数减少。
  void noteFilesRemoved(String dir, int count) {
    unawaited(_adjust(dir, -count, null));
  }

  /// 无法可靠增量时失效目录缓存，由下次统计重建。
  void invalidate(String dir) {
    final session = _sessionProvider();
    if (session == null || !session.isRemote) return;
    final accountKey = _accountKeyOf(session);
    if (accountKey == null) return;
    unawaited(_cache.invalidate(dir, accountKey: accountKey));
  }

  Future<void> _adjust(String dir, int delta, DateTime? at) async {
    try {
      final session = _sessionProvider();
      if (session == null || !session.isRemote) return;
      final accountKey = _accountKeyOf(session);
      if (accountKey == null) return;
      await _cache.adjust(
        dir,
        itemCountDelta: delta,
        updatedAt: at,
        accountKey: accountKey,
      );
    } catch (error) {
      debugPrint('[directory-summary] 写时修正失败 $dir: $error');
    }
  }
}
