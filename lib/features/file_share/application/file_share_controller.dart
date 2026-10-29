import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import '../../auth/application/session_controller.dart';
import '../../workspace/domain/file_item.dart';
import '../../workspace/infrastructure/oss_client.dart';
import '../domain/file_share_models.dart';
import '../infrastructure/share_cache_store.dart';

typedef ShareFilesInvoker = Future<ShareResult> Function(List<String> localPaths);

/// Android 文件系统分享：校验可用条件、准备本地副本并调起系统分享面板。
///
/// 支持单个或多个文件；分享准备不进入传输中心，也不写入系统相册，
/// 缓存命中时直接复用。
class FileShareController extends ChangeNotifier {
  FileShareController({
    required SessionController sessionController,
    required OssClient ossClient,
    ShareCacheStore? cacheStore,
    ShareFilesInvoker? shareInvoker,
  })  : _sessionController = sessionController,
        _ossClient = ossClient,
        _cacheStore = cacheStore ?? ShareCacheStore(),
        _shareInvoker = shareInvoker ?? _defaultShareInvoker;

  static Future<ShareResult> _defaultShareInvoker(List<String> localPaths) =>
      SharePlus.instance.share(
        ShareParams(
          files: localPaths.map(XFile.new).toList(growable: false),
        ),
      );

  final SessionController _sessionController;
  final OssClient _ossClient;
  final ShareCacheStore _cacheStore;
  final ShareFilesInvoker _shareInvoker;

  /// 准备进度；准备完成、失败或取消后置空。
  final ValueNotifier<ShareProgress?> progressListenable =
      ValueNotifier<ShareProgress?>(null);

  bool _preparing = false;
  bool _cancelRequested = false;
  String? _taskId;

  bool get isPreparing => _preparing;

  /// 分享临时文件缓存：设置页统一清理缓存时复用同一实例。
  ShareCacheStore get cacheStore => _cacheStore;

  /// 单个条目的分享入口可用条件：Android、具备下载能力、非别名普通文件。
  bool canShare(FileItem item) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    if (!_sessionController.capabilities.download) return false;
    return !item.isDirectory && !item.isAlias;
  }

  /// 批量分享条件：至少一个条目，且全部为非别名普通文件。
  bool canShareAll(Iterable<FileItem> items) {
    final list = items.toList(growable: false);
    return list.isNotEmpty && list.every(canShare);
  }

  Future<File?> lookup(FileItem item) async {
    _ensureCanShare(item);
    return _cacheStore.lookup(item);
  }

  /// 确保单个文件的本地副本可用。
  Future<File> prepare(FileItem item) async {
    final files = await prepareAll(<FileItem>[item]);
    return files.single;
  }

  /// 按选择顺序逐个准备本地副本：优先复用缓存，未命中时下载。
  ///
  /// 批次内只清理一次缓存，避免把本批次已准备的副本淘汰掉。
  Future<List<File>> prepareAll(List<FileItem> items) async {
    if (items.isEmpty) {
      throw StateError('没有可分享的文件');
    }
    for (final item in items) {
      _ensureCanShare(item);
    }
    if (_preparing) {
      throw StateError('已有分享准备进行中');
    }

    _preparing = true;
    _cancelRequested = false;
    final fileCount = items.length;
    final overallTotal = items.every((item) => item.size != null)
        ? items.fold<int>(0, (sum, item) => sum + item.size!)
        : null;
    _emitProgress(items.first, 0, overallTotal, 1, fileCount);
    notifyListeners();

    final results = <File>[];
    var completedBytes = 0;
    try {
      await _cacheStore.clean();
      for (var index = 0; index < fileCount; index++) {
        if (_cancelRequested) {
          throw const FileShareCanceledException();
        }
        final item = items[index];
        final fileIndex = index + 1;
        _emitProgress(item, completedBytes, overallTotal, fileIndex, fileCount);

        final target = await _cacheStore.fileFor(item);
        final cached = await _cacheStore.lookup(item);
        if (cached != null) {
          results.add(cached);
          completedBytes += item.size ?? await cached.length();
          continue;
        }

        await _sessionController.ensureSessionReady();
        final session = _sessionController.requireSession();
        final taskId =
            'file-share-${DateTime.now().microsecondsSinceEpoch}-$index';
        _taskId = taskId;

        File? temporary;
        try {
          temporary = await _cacheStore.temporaryFileFor(target);
          await _ossClient.downloadToFile(
            item.path,
            session,
            temporary,
            taskId: taskId,
            onProgress: (receivedBytes, totalBytes) {
              if (_cancelRequested) return;
              final total = fileCount == 1
                  ? (totalBytes ?? overallTotal)
                  : overallTotal;
              _emitProgress(
                item,
                completedBytes + receivedBytes,
                total,
                fileIndex,
                fileCount,
              );
            },
            isCanceled: () => _cancelRequested,
          );
          if (_cancelRequested) {
            throw const TransferCanceledException();
          }
          final committed = await _cacheStore.commit(temporary, target);
          temporary = null;
          results.add(committed);
          completedBytes += item.size ?? await committed.length();
        } on TransferCanceledException {
          throw const FileShareCanceledException();
        } finally {
          _taskId = null;
          if (temporary != null) {
            await _cacheStore.discard(temporary);
          }
        }
      }
      return results;
    } finally {
      _preparing = false;
      _cancelRequested = false;
      _taskId = null;
      progressListenable.value = null;
      notifyListeners();
    }
  }

  /// 取消准备：中止当前下载，由 [prepareAll] 清理临时文件并抛出取消异常。
  void cancelPreparation() {
    if (!_preparing) return;
    _cancelRequested = true;
    final taskId = _taskId;
    if (taskId != null) {
      unawaited(_ossClient.cancelTransfer(taskId));
    }
    notifyListeners();
  }

  /// 调起系统分享面板；dismissed 视为用户取消，异常统一按失败处理。
  Future<FileShareOutcome> shareFiles(List<String> localPaths) async {
    if (localPaths.isEmpty) return FileShareOutcome.failed;
    try {
      final result = await _shareInvoker(localPaths);
      return switch (result.status) {
        ShareResultStatus.success => FileShareOutcome.success,
        ShareResultStatus.dismissed => FileShareOutcome.canceled,
        ShareResultStatus.unavailable => FileShareOutcome.failed,
      };
    } catch (_) {
      return FileShareOutcome.failed;
    }
  }

  Future<int> cleanCache({
    Set<String> keepPaths = const <String>{},
  }) async {
    final removed = await _cacheStore.clean(keepPaths: keepPaths);
    if (removed > 0) {
      debugPrint('[file-share] 已清理 $removed 个分享缓存文件');
    }
    return removed;
  }

  void _emitProgress(
    FileItem item,
    int receivedBytes,
    int? totalBytes,
    int fileIndex,
    int fileCount,
  ) {
    progressListenable.value = ShareProgress(
      fileName: item.name,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
      fileIndex: fileIndex,
      fileCount: fileCount,
    );
  }

  void _ensureCanShare(FileItem item) {
    if (!canShare(item)) {
      throw StateError('当前平台或身份不支持分享');
    }
  }

  @override
  void dispose() {
    progressListenable.dispose();
    super.dispose();
  }
}
