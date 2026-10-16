import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../shared/gallery_index_hooks.dart';
import '../../../shared/path_utils.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/user_session.dart';
import '../domain/file_item.dart';
import '../domain/move_models.dart';
import '../domain/move_task_entry.dart';
import '../infrastructure/oss_client.dart';
import 'workspace_controller.dart';

/// 一次移动执行的单源计划：源前缀与其在目标侧的落点（重命名后）。
class _MovePlanPair {
  const _MovePlanPair({required this.source, required this.renameRoot});

  final String source;
  final String renameRoot;
}

/// 移动域的编排层：移动全流程、冲突处置与中断任务的继续/撤销。
///
/// 持有移动进行中状态（[moveStateListenable]）；导航上下文与相册索引
/// 挂钩由调用方注入。
class MoveController extends ChangeNotifier {
  MoveController({
    required SessionController sessionController,
    required WorkspaceController workspaceController,
    required OssClient ossClient,
  })  : _sessionController = sessionController,
        _workspaceController = workspaceController,
        _ossClient = ossClient;

  static const _movesRoot = '$rootPrefix.moves/';

  final SessionController _sessionController;
  final WorkspaceController _workspaceController;
  final OssClient _ossClient;

  GlobalKey<NavigatorState>? _navigatorKey;
  GalleryIndexHooks? _galleryHooks;

  /// 冲突处置弹窗使用的导航上下文，由装配方注入。
  void setNavigatorKey(GlobalKey<NavigatorState>? key) {
    _navigatorKey = key;
  }

  /// 搬运涉及的相册索引挂钩（对象删除/还原回调）。
  void setGalleryHooks(GalleryIndexHooks? hooks) {
    _galleryHooks = hooks;
  }

  /// 移动进行中状态（已处理/总对象数）；仅工作区条目区消费，避免整页重建。
  final ValueNotifier<MoveProgress?> moveStateListenable =
      ValueNotifier<MoveProgress?>(null);
  bool _isMoving = false;

  bool get isMoving => _isMoving;

  /// 发起移动：源去重 → 目标合法性校验 → 冲突检测与处置 → 写 manifest → 执行。
  /// 返回 null 表示用户在冲突处置或互斥检查后取消，未产生任何搬运。
  Future<MoveSummary?> moveItems(
    List<FileItem> items,
    String targetDir,
  ) async {
    if (_isMoving) {
      throw StateError('已有移动任务进行中，请等待完成');
    }
    _sessionController.ensureUploadCapability();
    _sessionController.ensureDeleteCapability();
    final targetPrefix = normalizeDirPath(targetDir);
    await _sessionController.ensureSessionReady();
    final session = _sessionController.requireSession();

    final sources = _dedupeMoveSources(items);
    if (sources.isEmpty) {
      throw StateError('没有可移动的条目');
    }
    _validateMoveTargets(sources, targetPrefix);

    final plan = await _planMove(sources, targetPrefix, session);
    if (plan == null) {
      return null;
    }
    final summary = await _executeMovePlan(
      plan: plan,
      targetPrefix: targetPrefix,
      session: session,
    );
    _refreshAfterMove(
      sources.map((item) => item.path),
      plan.map((pair) => pair.renameRoot),
      summary,
    );
    unawaited(_galleryHooks?.onObjectsDeleted(summary.sourceKeys));
    unawaited(_galleryHooks?.onObjectsRestored(summary.destinationKeys));
    return summary;
  }

  /// 对包含父文件夹与其子项的选择去重：父前缀已覆盖子路径。
  List<FileItem> _dedupeMoveSources(List<FileItem> items) {
    final sorted = items.toList(growable: false)
      ..sort((a, b) => a.path.length.compareTo(b.path.length));
    final sources = <FileItem>[];
    for (final item in sorted) {
      _workspaceController.ensureWithinRoot(item.path);
      if (sources.any((source) =>
          item.path.startsWith(normalizeDirPath(source.path)) ||
          item.path == source.path)) {
        continue;
      }
      sources.add(item);
    }
    return sources;
  }

  /// 目标不得为任何源目录自身或其子目录，也不得与全部源的所在目录相同。
  void _validateMoveTargets(List<FileItem> sources, String targetPrefix) {
    for (final item in sources) {
      if (!item.isDirectory) continue;
      final dirPrefix = normalizeDirPath(item.path);
      if (targetPrefix == dirPrefix || targetPrefix.startsWith(dirPrefix)) {
        throw StateError('目标目录不能是「${item.name}」自身或其子目录');
      }
    }
    final sameAsSourceParent = sources
        .every((item) => normalizeDirPath(parentPathOf(item.path)) == targetPrefix);
    if (sameAsSourceParent) {
      throw StateError('目标目录与源所在目录相同，无需移动');
    }
  }

  /// 逐条目检测目标路径冲突并生成执行计划；存在冲突时向用户请求处置。
  Future<List<_MovePlanPair>?> _planMove(
    List<FileItem> sources,
    String targetPrefix,
    UserSession session,
  ) async {
    final desiredPaths = <String>[
      for (final item in sources)
        '$targetPrefix${item.name}${item.isDirectory ? '/' : ''}',
    ];
    final exists = await Future.wait(desiredPaths
        .map((desired) => _ossClient.objectExists(desired, session)));
    final conflicts = <FileItem>[
      for (var index = 0; index < sources.length; index++)
        if (exists[index]) sources[index],
    ];
    var resolution = MoveConflictResolution.keepBoth;
    if (conflicts.isNotEmpty) {
      final decision =
          await _showMoveConflictDialog(conflicts.map((item) => item.name)
              .toList(growable: false));
      if (decision == null) {
        return null;
      }
      resolution = decision;
    }
    final plan = <_MovePlanPair>[];
    for (final item in sources) {
      if (conflicts.contains(item) && resolution == MoveConflictResolution.skip) {
        continue;
      }
      var name = item.name;
      if (conflicts.contains(item)) {
        name = (await _nonConflictingObjectPath(
                '$targetPrefix$name${item.isDirectory ? '/' : ''}', session))
            .substring(targetPrefix.length)
            .replaceFirst(RegExp(r'/$'), '');
      }
      plan.add(_MovePlanPair(
        source: item.path,
        renameRoot: '$targetPrefix$name${item.isDirectory ? '/' : ''}',
      ));
    }
    return plan;
  }

  /// 写 manifest 后逐对象 copy→delete 执行计划；全部成功时删除 manifest，
  /// 存在失败时保留 manifest 供冷启动继续或撤销。
  Future<MoveSummary> _executeMovePlan({
    required List<_MovePlanPair> plan,
    required String targetPrefix,
    required UserSession session,
    String? manifestId,
  }) async {
    _isMoving = true;
    notifyListeners();
    final id = manifestId ??
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final manifestKey = '$_movesRoot$id/manifest.json';
    try {
      final entry = MoveTaskEntry(
        id: id,
        sourcePrefixes: plan.map((pair) => pair.source).toList(growable: false),
        destinations: plan.map((pair) => pair.renameRoot).toList(growable: false),
        targetPrefix: targetPrefix,
        createdAt: DateTime.now(),
      );
      await _ossClient.uploadText(manifestKey, entry.encode(), session);
      final summary = await _runMovePlan(plan, session);
      if (!summary.hasFailures) {
        try {
          await _ossClient.delete(manifestKey, session);
        } catch (_) {
          // manifest 删除失败仅残留一个可再次处理的任务，不影响结果。
        }
      }
      return summary;
    } finally {
      _isMoving = false;
      moveStateListenable.value = null;
      notifyListeners();
    }
  }

  Future<MoveSummary> _runMovePlan(
    List<_MovePlanPair> plan,
    UserSession session,
  ) async {
    final failed = <String>{};
    final sourceKeys = <String>{};
    final destinationKeys = <String>{};
    var processed = 0;
    var total = 0;
    var counting = true;

    void publish() {
      moveStateListenable.value = MoveProgress(
        processed: processed,
        total: total,
        isCounting: counting,
      );
    }

    publish();

    // 把一批（≤并发数）对象 copy → deleteMany；单对象 copy 先于其源
    // delete 的不变式在批粒度成立，中断重跑幂等收敛。
    Future<void> moveChunk(List<({String key, String dst})> chunk) async {
      await Future.wait(chunk.map((item) async {
        try {
          await _ossClient.copy(item.key, item.dst, session);
        } catch (_) {
          // 复制失败可能源于上一轮已完成搬运（源已消失）：目标侧存在且源
          // 已不存在即视为完成；目录标记缺失时改用建目录方式补齐。
          final sourceExists = await _safeObjectExists(item.key, session);
          if (sourceExists) {
            failed.add(item.key);
          } else if (await _safeObjectExists(item.dst, session) ||
              (item.key.endsWith('/') &&
                  await _createDirectoryMarker(item.dst, session))) {
            // 已在上一轮完成 / 空目录标记补齐。
          } else {
            failed.add(item.key);
          }
        }
        processed++;
        publish();
      }));
      final pendingDeletes = chunk
          .map((item) => item.key)
          .where((key) => !failed.contains(key))
          .toSet();
      if (pendingDeletes.isEmpty) return;
      try {
        final result = await _ossClient.deleteMany(pendingDeletes, session);
        failed.addAll(result.failedPaths);
      } catch (_) {
        // 复制已成功但删除失败：目标侧已有副本，重跑可幂等收敛。
        failed.addAll(pendingDeletes);
      }
    }

    // 把一组 key 投入搬运（按批并发），并计入进度总数。
    Future<void> moveKeys(Iterable<String> keys, _MovePlanPair pair) async {
      final work = <({String key, String dst})>[
        for (final key in keys)
          (
            key: key,
            dst: key == pair.source
                ? pair.renameRoot
                : '${pair.renameRoot}${key.substring(pair.source.length)}',
          ),
      ];
      if (work.isEmpty) return;
      total += work.length;
      publish();
      sourceKeys.addAll(work.map((item) => item.key));
      destinationKeys.addAll(work.map((item) => item.dst));
      const concurrency = 6;
      for (var start = 0; start < work.length; start += concurrency) {
        final end = start + concurrency > work.length
            ? work.length
            : start + concurrency;
        await moveChunk(work.sublist(start, end));
      }
    }

    // 边列举边搬运：递归列举每返回一页即把该页投入搬运，列举下一页与
    // 搬运并发进行，总耗时 ≈ max(列举, 搬运) 而非两者相加。
    final pageJobs = <Future<void>>[];
    for (final pair in plan) {
      if (!pair.source.endsWith('/')) {
        pageJobs.add(moveKeys(<String>[pair.source], pair));
        continue;
      }
      // 目录标记单独投入：已完成的续迁中标记可能已随源消失，按幂等处理。
      pageJobs.add(moveKeys(<String>[pair.source], pair));
      await _ossClient.forEachObjectKeyPage(pair.source, session, (keys) async {
        final page = keys.where((key) => key != pair.source).toList();
        if (page.isEmpty) return;
        pageJobs.add(moveKeys(page, pair));
      });
    }
    counting = false;
    publish();
    await Future.wait(pageJobs);
    return MoveSummary(
      movedCount: sourceKeys.length - failed.length,
      failedKeys: failed.toList(growable: false),
      sourceKeys: sourceKeys,
      destinationKeys: destinationKeys,
    );
  }

  Future<bool> _safeObjectExists(String path, UserSession session) async {
    try {
      return await _ossClient.objectExists(path, session);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _createDirectoryMarker(String path, UserSession session) async {
    try {
      await _ossClient.createFolder(path, session);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 生成不冲突的目标路径：优先原名，其次「名称（n）」后缀，绝不覆盖。
  Future<String> _nonConflictingObjectPath(
      String desired, UserSession session) async {
    if (!await _ossClient.objectExists(desired, session)) return desired;
    final directory = parentPathOf(desired);
    final raw = desired.substring(directory.length);
    final isDirectory = raw.endsWith('/');
    final name = isDirectory ? raw.substring(0, raw.length - 1) : raw;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var number = 1;; number++) {
      final candidate =
          '$directory$stem（$number）$extension${isDirectory ? '/' : ''}';
      if (!await _ossClient.objectExists(candidate, session)) return candidate;
    }
  }

  Future<MoveConflictResolution?> _showMoveConflictDialog(
      List<String> conflictingNames) async {
    final context = _navigatorKey?.currentContext;
    if (context == null) {
      return null;
    }
    var selected = MoveConflictResolution.keepBoth;
    return showDialog<MoveConflictResolution>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: const Text('目标目录存在同名条目'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '「${conflictingNames.take(3).join('、')}'
                '${conflictingNames.length > 3 ? ' 等 ${conflictingNames.length} 项' : ''}」'
                '在目标目录已存在，请选择处理方式。',
              ),
              RadioGroup<MoveConflictResolution>(
                groupValue: selected,
                onChanged: (value) =>
                    setState(() => selected = value ?? selected),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    RadioListTile<MoveConflictResolution>(
                      title: const Text('保留两者'),
                      subtitle: const Text('同名条目自动追加序号后移动'),
                      value: MoveConflictResolution.keepBoth,
                    ),
                    RadioListTile<MoveConflictResolution>(
                      title: const Text('跳过'),
                      subtitle: const Text('跳过同名条目，移动其余内容'),
                      value: MoveConflictResolution.skip,
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消整个移动'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(selected),
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
  }

  /// 列出 OSS 上未完成的移动任务 manifest。
  Future<List<MoveTaskEntry>> listPendingMoves() async {
    await _sessionController.ensureSessionReady();
    final session = _sessionController.requireSession();
    final prefixes = await _ossClient.listPrefixes(_movesRoot, session);
    final entries = <MoveTaskEntry>[];
    for (final prefix in prefixes) {
      try {
        entries.add(MoveTaskEntry.decode(
          utf8.decode(
              await _ossClient.download('$prefix' 'manifest.json', session)),
        ));
      } catch (_) {
        // manifest 未写完或已损坏，等待用户通过继续/撤销流程清理。
      }
    }
    entries.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return entries;
  }

  /// 继续未完成的移动：按 manifest 幂等重跑，已搬走的对象自然跳过。
  Future<MoveSummary> resumePendingMove(MoveTaskEntry entry) async {
    if (_isMoving) {
      throw StateError('已有移动任务进行中，请等待完成');
    }
    _sessionController.ensureUploadCapability();
    _sessionController.ensureDeleteCapability();
    await _sessionController.ensureSessionReady();
    final session = _sessionController.requireSession();
    final plan = _planFromEntry(entry);
    final summary = await _executeMovePlan(
      plan: plan,
      targetPrefix: entry.targetPrefix,
      session: session,
      manifestId: entry.id,
    );
    _refreshAfterMove(
      entry.sourcePrefixes,
      plan.map((pair) => pair.renameRoot),
      summary,
    );
    unawaited(_galleryHooks?.onObjectsDeleted(summary.sourceKeys));
    unawaited(_galleryHooks?.onObjectsRestored(summary.destinationKeys));
    return summary;
  }

  /// 撤销未完成的移动：把目标侧已搬运对象反向搬回源位置，冲突时自动改名。
  Future<MoveSummary> undoPendingMove(MoveTaskEntry entry) async {
    if (_isMoving) {
      throw StateError('已有移动任务进行中，请等待完成');
    }
    _sessionController.ensureUploadCapability();
    _sessionController.ensureDeleteCapability();
    await _sessionController.ensureSessionReady();
    final session = _sessionController.requireSession();
    final plan = _planFromEntry(entry);
    _isMoving = true;
    notifyListeners();
    final failed = <String>{};
    final deletedKeys = <String>{};
    final restoredKeys = <String>{};
    var processed = 0;
    var total = 0;
    var counting = true;

    void publish() {
      moveStateListenable.value = MoveProgress(
        processed: processed,
        total: total,
        isUndo: true,
        isCounting: counting,
      );
    }

    try {
      // 规划阶段要逐个探测源/目标对象（多次请求），先把“撤销中”状态
      // 公布出去，避免界面长时间无反馈。
      publish();
      Future<void> undoChunk(
          List<({String key, String dst, bool copyBack})> chunk) async {
        await Future.wait(chunk.map((item) async {
          if (item.copyBack) {
            try {
              await _ossClient.copy(item.key, item.dst, session);
            } catch (_) {
              failed.add(item.key);
            }
          }
          processed++;
          publish();
        }));
        final pendingDeletes = chunk
            .map((item) => item.key)
            .where((key) => !failed.contains(key))
            .toSet();
        if (pendingDeletes.isEmpty) return;
        try {
          final result = await _ossClient.deleteMany(pendingDeletes, session);
          failed.addAll(result.failedPaths);
        } catch (_) {
          failed.addAll(pendingDeletes);
        }
      }

      // 探测一组 key 的源位置占用并解析最终 dst，随后按批并发搬回。
      Future<void> undoKeys(List<String> keys, _MovePlanPair pair) async {
        const concurrency = 6;
        for (var start = 0; start < keys.length; start += concurrency) {
          final end =
              start + concurrency > keys.length ? keys.length : start + concurrency;
          final chunk = keys.sublist(start, end);
          final resolved = <({String key, String dst, bool copyBack})>[];
          await Future.wait(chunk.map((key) async {
            final relative = key.startsWith(pair.renameRoot) &&
                    pair.renameRoot.length > entry.targetPrefix.length
                ? key.substring(pair.renameRoot.length)
                : key.substring(entry.targetPrefix.length);
            var dst = '${pair.source}$relative';
            if (await _safeObjectExists(dst, session)) {
              // 源位置已有同名对象：中断批次常使源、目标两侧各存一份相同副本
              // （复制完成后尚未删源），此时直接丢弃目标侧副本即可恢复移动前
              // 状态；仅当两侧内容不同（源位置在移动期间被重新占用）时才改名
              // 保留目标侧副本。目录标记恒为 0 字节，直接判同。
              final duplicate = key.endsWith('/') ||
                  await _isSameObjectSize(key, dst, session);
              if (duplicate) {
                resolved.add((key: key, dst: key, copyBack: false));
                return;
              }
              dst = await _nonConflictingObjectPath(dst, session);
            }
            resolved.add((key: key, dst: dst, copyBack: true));
          }));
          total += resolved.length;
          publish();
          deletedKeys.addAll(resolved.map((item) => item.key));
          restoredKeys.addAll(
              resolved.where((item) => item.copyBack).map((item) => item.dst));
          await undoChunk(resolved);
        }
      }

      // 边列举边搬回：与正向移动一致，每页 key 到达即投入处理。
      final pageJobs = <Future<void>>[];
      for (final pair in plan) {
        if (!await _safeObjectExists(pair.renameRoot, session)) {
          // 目标侧不存在：未开始搬运或已被撤销，无需处理。
          debugPrint('[move] 撤销跳过：目标侧不存在 ${pair.renameRoot}');
          continue;
        }
        if (!pair.source.endsWith('/')) {
          pageJobs.add(undoKeys(<String>[pair.renameRoot], pair));
          continue;
        }
        // 目录标记单独投入：已撤销过的续跑中标记可能已随目标侧消失，幂等处理。
        pageJobs.add(undoKeys(<String>[pair.renameRoot], pair));
        await _ossClient.forEachObjectKeyPage(
            pair.renameRoot, session, (keys) async {
          final page = keys.where((key) => key != pair.renameRoot).toList();
          if (page.isEmpty) return;
          pageJobs.add(undoKeys(page, pair));
        });
      }
      counting = false;
      publish();
      await Future.wait(pageJobs);
      if (kDebugMode) {
        debugPrint(
          '[move] 撤销计划：${plan.map((p) => '${p.source} <= ${p.renameRoot}').join('；')}，待搬回 $total 项',
        );
      }
      if (failed.isEmpty) {
        try {
          await _ossClient.delete(
              '$_movesRoot${entry.id}/manifest.json', session);
        } catch (_) {
          // manifest 删除失败仅残留任务，不影响撤销结果。
        }
      }
    } finally {
      _isMoving = false;
      moveStateListenable.value = null;
      notifyListeners();
    }
    if (kDebugMode && failed.isNotEmpty) {
      debugPrint('[move] 撤销失败对象（前 5 个）: ${failed.take(5).join(', ')}');
    }
    // 撤销后失效目标侧缓存（目录从目标位置消失），源侧目录标记为存在。
    _refreshAfterMove(
      plan.map((pair) => pair.renameRoot).toSet(),
      entry.sourcePrefixes.toSet(),
      MoveSummary(
        movedCount: total - failed.length,
        failedKeys: failed.toList(growable: false),
      ),
    );
    unawaited(_galleryHooks?.onObjectsDeleted(deletedKeys));
    unawaited(_galleryHooks?.onObjectsRestored(restoredKeys));
    return MoveSummary(
        movedCount: total - failed.length,
        failedKeys: failed.toList(growable: false));
  }

  /// 以对象大小近似判断两个对象是否为同一副本（撤销场景的副本由复制产生）。
  Future<bool> _isSameObjectSize(
      String a, String b, UserSession session) async {
    final sizeA = await _objectSize(a, session);
    return sizeA != null && sizeA == await _objectSize(b, session);
  }

  Future<int?> _objectSize(String key, UserSession session) async {
    try {
      for (final object in await _ossClient.listAllObjects(key, session)) {
        if (object.key == key) {
          return object.size;
        }
      }
    } catch (_) {
      // 探测失败按“内容不同”处理，走改名保留路径。
    }
    return null;
  }

  List<_MovePlanPair> _planFromEntry(MoveTaskEntry entry) {
    return <_MovePlanPair>[
      for (var index = 0; index < entry.sourcePrefixes.length; index++)
        _MovePlanPair(
          source: entry.sourcePrefixes[index],
          renameRoot: entry.destinations.isNotEmpty &&
                  index < entry.destinations.length
              ? entry.destinations[index]
              : entry.targetPrefix +
                  entry.sourcePrefixes[index]
                      .substring(parentPathOf(entry.sourcePrefixes[index]).length),
        ),
    ];
  }

  /// 移动结束后统一刷新：目录缓存、侧边栏目录、当前路径与选择状态。
  void _refreshAfterMove(
    Iterable<String> removedPrefixes,
    Iterable<String> addedPrefixes,
    MoveSummary summary,
  ) {
    if (summary.movedCount == 0 && !summary.hasFailures) {
      return;
    }
    for (final prefix in removedPrefixes) {
      final dir = normalizeDirPath(prefix);
      _workspaceController.removeBrowsedDirectoriesWhere(
          (path) => path == dir || path.startsWith(dir));
      if (_workspaceController.currentPath.startsWith(dir)) {
        _workspaceController.replaceCurrentPath(parentPathOf(dir));
      }
    }
    _workspaceController.addBrowsedDirectories(addedPrefixes);
    _workspaceController.bumpTreeRevision();
    _workspaceController.clearDirectorySizeCache();
    // 移动同时修正源目录与目标目录：正向移动 removedPrefixes 为源条目、
    // addedPrefixes 为目标落点；撤销移动时两者互换，同一套修正逻辑成立。
    _workspaceController.noteTopLevelChanges(
      removedPrefixes,
      summary.hasFailures ? removedPrefixes.toSet() : const <String>{},
      delta: -1,
    );
    _workspaceController.noteTopLevelChanges(
      addedPrefixes,
      summary.hasFailures ? addedPrefixes.toSet() : const <String>{},
      delta: 1,
    );
    final selected = _workspaceController.selectedItem;
    if (selected != null &&
        removedPrefixes.any(
            (prefix) => selected.path.startsWith(normalizeDirPath(prefix)))) {
      _workspaceController.clearSelectedItem();
    }
    _workspaceController.clearMultiSelection();
    notifyListeners();
  }

  @override
  void dispose() {
    moveStateListenable.dispose();
    super.dispose();
  }
}
