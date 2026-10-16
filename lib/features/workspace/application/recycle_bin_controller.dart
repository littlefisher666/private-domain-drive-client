import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../shared/gallery_index_hooks.dart';
import '../../../shared/path_utils.dart';
import '../../../core/errors/app_error.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/user_session.dart';
import '../domain/delete_models.dart';
import '../domain/file_item.dart';
import '../domain/recycle_bin_entry.dart';
import '../infrastructure/oss_client.dart';
import 'workspace_controller.dart';

/// 删除与回收站域的编排层：删除（移入回收站）全流程、回收站列举/还原/
/// 彻底删除，以及回收站内导航状态。
///
/// 持有删除进行中状态（[deleteStateListenable]）；相册索引挂钩由调用方注入。
class RecycleBinController extends ChangeNotifier {
  RecycleBinController({
    required SessionController sessionController,
    required WorkspaceController workspaceController,
    required OssClient ossClient,
  })  : _sessionController = sessionController,
        _workspaceController = workspaceController,
        _ossClient = ossClient;

  static const _trashRoot = '$rootPrefix.trash/';

  final SessionController _sessionController;
  final WorkspaceController _workspaceController;
  final OssClient _ossClient;

  GalleryIndexHooks? _galleryHooks;

  /// 删除/还原涉及的相册索引挂钩（对象删除/还原回调）。
  void setGalleryHooks(GalleryIndexHooks? hooks) {
    _galleryHooks = hooks;
  }

  /// 删除（移入回收站）进行中状态；非阻塞横幅消费，删除期间不锁界面。
  final ValueNotifier<DeleteProgress?> deleteStateListenable =
      ValueNotifier<DeleteProgress?>(null);

  String _recycleBinPath = rootPrefix;

  String get recycleBinPath => _recycleBinPath;

  void setRecycleBinPath(String path) {
    _recycleBinPath = normalizeDirPath(path);
    notifyListeners();
  }

  /// 回收站内返回上一级：处于某个条目根层时回到回收站根层。
  String recycleBinUpPath() {
    final current = normalizeDirPath(_recycleBinPath);
    final root = normalizeDirPath(rootPrefix);
    if (current == root) return root;
    if (current.startsWith(_trashRoot)) {
      final rest = current.substring(_trashRoot.length);
      final segments = rest.split('/').where((segment) => segment.isNotEmpty);
      if (segments.length <= 1) return root;
    }
    return parentPathOf(current);
  }

  Future<void> deleteItem(FileItem item) async {
    _sessionController.ensureDeleteCapability();
    await _sessionController.ensureSessionReady();
    final session = _sessionController.requireSession();
    // 大目录先列全量 key，耗时较长；先置进度让横幅立即可见。
    deleteStateListenable.value = const DeleteProgress(processed: 0, total: 0);
    final paths = <String>{item.path};
    if (item.isDirectory) {
      paths.addAll(await _ossClient.listAllObjectKeys(item.path, session));
    }
    final result = await _moveToRecycleBin(
      _planRecycleBinItems(<FileItem>[item], paths),
      session: session,
    );
    if (result.failedPaths.isNotEmpty) {
      throw StateError('有 ${result.failedPaths.length} 个对象未能移入回收站');
    }
    if (item.isDirectory) {
      final deletedPath = normalizeDirPath(item.path);
      _workspaceController.removeBrowsedDirectoriesWhere(
        (path) => path == deletedPath || path.startsWith(deletedPath),
      );
      if (_workspaceController.currentPath.startsWith(deletedPath)) {
        _workspaceController.replaceCurrentPath(parentPathOf(deletedPath));
      }
    }
    _workspaceController.bumpTreeRevision();
    _workspaceController.clearDirectorySizeCache();
    _workspaceController.noteTopLevelChanges(
      <String>[item.path],
      const <String>{},
      delta: -1,
    );

    if (_workspaceController.selectedItem?.path == item.path) {
      _workspaceController.clearSelectedItem();
    }
    unawaited(_galleryHooks?.onObjectsDeleted(paths));
    notifyListeners();
  }

  Future<BatchDeletePreview> prepareBatchDelete(
    Iterable<FileItem> items,
  ) async {
    _sessionController.ensureDeleteCapability();
    final selected = items.toList(growable: false);
    final paths = <String>{};
    await _sessionController.ensureSessionReady();
    final session = _sessionController.requireSession();
    for (final item in selected) {
      _workspaceController.ensureWithinRoot(item.path);
      paths.add(item.path);
      if (item.isDirectory) {
        paths.addAll(await _ossClient.listAllObjectKeys(item.path, session));
      }
    }
    return BatchDeletePreview(
      selectedCount: selected.length,
      directoryCount: selected.where((item) => item.isDirectory).length,
      objectPaths: paths,
      topLevelPaths: selected.map((item) => item.path).toSet(),
      items: selected,
    );
  }

  Future<BatchDeleteSummary> deleteBatch(
    BatchDeletePreview preview,
  ) async {
    _sessionController.ensureDeleteCapability();
    await _sessionController.ensureSessionReady();
    final result = await _moveToRecycleBin(
      _planRecycleBinItems(preview.items, preview.objectPaths),
      session: _sessionController.requireSession(),
    );
    final deleted = result.deletedPaths;
    final failed = result.failedPaths;
    if (deleted.isNotEmpty) {
      _workspaceController.clearDirectorySizeCache();
      _workspaceController.removeBrowsedDirectoriesWhere(
          (path) => deleted.contains(path));
      if (deleted.any((path) =>
          _workspaceController.currentPath.startsWith(normalizeDirPath(path)))) {
        _workspaceController.replaceCurrentPath(
            parentPathOf(_workspaceController.currentPath));
      }
      _workspaceController.bumpTreeRevision();
      _workspaceController.clearSelectedItem();
      _workspaceController.noteTopLevelChanges(
        preview.topLevelPaths,
        failed.toSet(),
        delta: -1,
      );
      unawaited(_galleryHooks?.onObjectsDeleted(deleted.toSet()));
      notifyListeners();
    }
    return BatchDeleteSummary(deletedPaths: deleted, failedPaths: failed);
  }

  /// 按用户勾选的顶层条目把对象路径归组，逐条目建立独立回收条目。
  ///
  /// 目录条目认领其前缀下的对象；文件条目只认领自身路径。先按路径
  /// 深度排序保证父目录先认领；未被任何条目认领的对象（如嵌套选中
  /// 被父目录覆盖）不重复归属。条目没有任何对象时跳过。
  List<({FileItem item, List<String> objectPaths})> _planRecycleBinItems(
    List<FileItem> items,
    Set<String> objectPaths,
  ) {
    final sources = objectPaths
        .where((path) => path.startsWith(rootPrefix))
        .toSet();
    final sorted = items.toList(growable: false)
      ..sort((a, b) {
        final byLength = a.path.length.compareTo(b.path.length);
        return byLength != 0 ? byLength : a.path.compareTo(b.path);
      });
    final claimed = <String>{};
    final planned = <({FileItem item, List<String> objectPaths})>[];
    for (final item in sorted) {
      final dir = item.isDirectory ? normalizeDirPath(item.path) : null;
      final owned = <String>[
        for (final path in sources)
          if (!claimed.contains(path) &&
              (dir != null
                  ? path == item.path || path.startsWith(dir)
                  : path == item.path))
            path,
      ];
      if (owned.isEmpty) continue;
      claimed.addAll(owned);
      planned.add((item: item, objectPaths: owned));
    }
    return planned;
  }

  Future<BatchDeleteSummary> _moveToRecycleBin(
    List<({FileItem item, List<String> objectPaths})> planned, {
    required UserSession session,
  }) async {
    final total = planned.fold<int>(0, (sum, plan) => sum + plan.objectPaths.length);
    deleteStateListenable.value = DeleteProgress(processed: 0, total: total);
    final copiedAll = <String, String>{};
    final failed = <String>[];
    try {
      final takenNames = await _recycleBinEntryNames(session);
      for (final plan in planned) {
        final id =
            '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
        final entryRoot = '$_trashRoot$id/';
        final copied = <String, String>{};
        // 与移动操作一致：小批次并发 copy，避免逐对象串行耗时过长。
        var done = deleteStateListenable.value?.processed ?? 0;
        const concurrency = 6;
        final sources = plan.objectPaths;
        for (var start = 0; start < sources.length; start += concurrency) {
          final end = min(start + concurrency, sources.length);
          await Future.wait(sources.sublist(start, end).map((source) async {
            final target =
                '$entryRoot' 'payload/${source.substring(rootPrefix.length)}';
            try {
              await _ossClient.copy(source, target, session);
              copied[source] = target;
            } catch (_) {
              failed.add(source);
            }
            done++;
            deleteStateListenable.value =
                DeleteProgress(processed: done, total: total);
          }));
        }
        if (copied.isNotEmpty) {
          final name = _uniqueRecycleBinName(
            plan.item.name,
            plan.item.isDirectory,
            takenNames,
          );
          takenNames.add(name);
          final entry = RecycleBinEntry(
            id: id,
            name: name,
            originalPath: plan.item.path,
            isDirectory: plan.item.isDirectory,
            deletedAt: DateTime.now(),
            objects: copied,
          );
          await _ossClient.uploadText(
              '$entryRoot' 'manifest.json', entry.encode(), session);
        }
        copiedAll.addAll(copied);
      }
      final deleted = <String>[];
      for (final keys in _batches(copiedAll.keys)) {
        try {
          final result = await _ossClient.deleteMany(keys, session);
          deleted.addAll(result.deletedPaths);
          failed.addAll(result.failedPaths);
        } catch (_) {
          failed.addAll(keys);
        }
      }
      return BatchDeleteSummary(deletedPaths: deleted, failedPaths: failed);
    } finally {
      deleteStateListenable.value = null;
    }
  }

  /// 已占用的回收条目展示名，用于重名去重。
  Future<Set<String>> _recycleBinEntryNames(UserSession session) async {
    try {
      return {
        for (final entry in await listRecycleBin()) entry.name,
      };
    } catch (_) {
      // 列举失败时退化为不去重，避免阻塞删除主流程。
      return <String>{};
    }
  }

  /// 为回收条目生成展示名：与现有条目重名时追加 `_yyyyMMdd_HHmmss`
  /// 时间戳（文件插在扩展名前，目录在末尾），仍冲突时再加序号。
  String _uniqueRecycleBinName(
    String rawName,
    bool isDirectory,
    Set<String> taken,
  ) {
    if (!taken.contains(rawName)) return rawName;
    final timestamp = _recycleBinTimestamp(DateTime.now());
    String stem;
    String extension;
    if (isDirectory) {
      stem = rawName;
      extension = '';
    } else {
      final dot = rawName.lastIndexOf('.');
      stem = dot > 0 ? rawName.substring(0, dot) : rawName;
      extension = dot > 0 ? rawName.substring(dot) : '';
    }
    var candidate = '$stem$extension';
    if (!taken.contains(candidate)) return candidate;
    var sequence = 1;
    do {
      sequence++;
      candidate = '${stem}_$timestamp${sequence > 2 ? '_$sequence' : ''}$extension';
    } while (taken.contains(candidate));
    return candidate;
  }

  String _recycleBinTimestamp(DateTime time) {
    final mm = time.month.toString().padLeft(2, '0');
    final dd = time.day.toString().padLeft(2, '0');
    final hh = time.hour.toString().padLeft(2, '0');
    final mi = time.minute.toString().padLeft(2, '0');
    final ss = time.second.toString().padLeft(2, '0');
    return '${time.year}$mm$dd' '_$hh$mi$ss';
  }

  Iterable<List<String>> _batches(Iterable<String> keys) sync* {
    final values = keys.toList(growable: false);
    for (var offset = 0; offset < values.length; offset += 1000) {
      yield values.sublist(offset, min(offset + 1000, values.length));
    }
  }

  Future<List<RecycleBinEntry>> listRecycleBin() async {
    await _sessionController.ensureSessionReady();
    final session = _sessionController.requireSession();
    final prefixes = await _ossClient.listPrefixes(_trashRoot, session);
    final entries = <RecycleBinEntry>[];
    for (final prefix in prefixes) {
      try {
        entries.add(RecycleBinEntry.decode(
          utf8.decode(
              await _ossClient.download('$prefix' 'manifest.json', session)),
        ));
      } catch (_) {
        // 未完成的回收批次没有 manifest，等待生命周期规则自动清理。
      }
    }
    entries.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return entries;
  }

  Future<void> restoreRecycleBinEntry(RecycleBinEntry entry) async {
    await _sessionController.ensureSessionReady();
    final session = _sessionController.requireSession();
    final restored = <String, String>{};
    for (final item in entry.objects.entries) {
      final destination = await _availableRestorePath(item.key, session);
      await _ossClient.copy(item.value, destination, session);
      restored[item.value] = destination;
    }
    for (final keys in _batches(<String>[
      ...restored.keys,
      '$_trashRoot${entry.id}/manifest.json'
    ])) {
      await _ossClient.deleteMany(keys, session);
    }
    _workspaceController.bumpTreeRevision();
    _workspaceController.clearDirectorySizeCache();
    // 还原目标位置可能带改名后缀，逐个失效还原目录，由校准重建。
    final restoredDirs = <String>{
      for (final destination in restored.values)
        normalizeDirPath(parentPathOf(destination)),
    };
    for (final dir in restoredDirs) {
      _workspaceController.invalidateDirectorySummary(dir);
      _workspaceController.calibrateDirectorySummary(dir);
    }
    unawaited(_galleryHooks?.onObjectsRestored(restored.values.toSet()));
    notifyListeners();
  }

  /// 立即删除一个回收条目；对象清单已覆盖条目的全部 payload 对象。
  Future<void> purgeRecycleBinEntry(RecycleBinEntry entry) async {
    await _sessionController.ensureSessionReady();
    final session = _sessionController.requireSession();
    final failed = <String>[];
    for (final keys in _batches(<String>[
      ...entry.objects.values,
      '$_trashRoot${entry.id}/manifest.json'
    ])) {
      final result = await _ossClient.deleteMany(keys, session);
      failed.addAll(result.failedPaths);
    }
    if (failed.isNotEmpty) {
      throw AppError('有 ${failed.length} 个对象删除失败，请稍后重试',
          code: 'OSS_DELETE_FAILED');
    }
    // 清空回收批次不影响可浏览目录的计数，仅失效原目录由校准重建。
    final originalDir = normalizeDirPath(parentPathOf(entry.originalPath));
    _workspaceController.invalidateDirectorySummary(originalDir);
    _workspaceController.calibrateDirectorySummary(originalDir);
    notifyListeners();
  }

  Future<String> _availableRestorePath(
      String desired, UserSession session) async {
    if (!await _ossClient.objectExists(desired, session)) return desired;
    final directory = parentPathOf(desired);
    final rawName = desired.substring(directory.length);
    final isDirectory = rawName.endsWith('/');
    final name =
        isDirectory ? rawName.substring(0, rawName.length - 1) : rawName;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var number = 0;; number++) {
      final suffix = number == 0 ? '（已还原）' : '（已还原 $number）';
      final candidate =
          '$directory$stem$suffix$extension${isDirectory ? '/' : ''}';
      if (!await _ossClient.objectExists(candidate, session)) return candidate;
    }
  }

  /// 重试部分失败的对象：按失败路径重建顶层条目（仅对象级信息，
  /// 展示名取路径末段），保持逐项独立回收条目的口径。
  Future<BatchDeleteSummary> retryBatchDelete(Iterable<String> failedPaths) {
    final paths = failedPaths.toSet();
    final items = <FileItem>[
      for (final path in paths)
        FileItem(
          path: path,
          name: path.endsWith('/')
              ? path.substring(0, path.length - 1).split('/').last
              : path.split('/').last,
          isDirectory: path.endsWith('/'),
        ),
    ];
    return deleteBatch(BatchDeletePreview(
      selectedCount: items.length,
      directoryCount: items.where((item) => item.isDirectory).length,
      objectPaths: paths,
      items: items,
    ));
  }

  @override
  void dispose() {
    deleteStateListenable.dispose();
    super.dispose();
  }
}
