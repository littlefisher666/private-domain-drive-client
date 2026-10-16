part of 'oss_client.dart';

/// 传输任务序号，保证 uploadText 的临时文件名与 taskId 全局唯一。
int _uploadTextSeq = 0;

/// 传输被用户或调用方取消时抛出。
class TransferCanceledException implements Exception {
  const TransferCanceledException();
}

/// 批量删除结果。
class BatchDeleteResult {
  const BatchDeleteResult({
    this.deletedPaths = const <String>[],
    this.failedPaths = const <String>[],
  });

  final List<String> deletedPaths;
  final List<String> failedPaths;
}

/// OssClient 的传输实现：上传/下载/流式下载/预签名 URL 与删除、复制、取消。
mixin _OssClientTransfer on _OssClientCore {
  Future<BatchDeleteResult> deleteMany(
    Iterable<String> paths,
    UserSession session,
  ) async {
    final requested = paths.toSet();
    if (requested.isEmpty) return const BatchDeleteResult();
    await _ensureConfigured(session);
    final result = await _platform(() => _native.deleteObjects(requested));
    return BatchDeleteResult(
      deletedPaths: result.deletedKeys,
      failedPaths: result.failedKeys,
    );
  }

  Future<void> delete(String path, UserSession session) async {
    await _ensureConfigured(session);
    await _platform(() => _native.deleteObject(path));
  }

  Future<void> uploadFile(
    String path,
    String localPath,
    UserSession session, {
    required String taskId,
    void Function(int transferredBytes, int totalBytes)? onProgress,
  }) async {
    await _ensureConfigured(session);
    await _withProgress(
      taskId: taskId,
      onProgress: (current, total) => onProgress?.call(current, total),
      operation: () => _native.uploadFile(
        taskId: taskId,
        key: path,
        localPath: localPath,
        multipartThresholdBytes:
            session.constraints.multipartUploadThresholdBytes,
      ),
    );
  }

  Future<void> uploadText(
      String path, String content, UserSession session) async {
    // 临时文件名必须唯一：writeAsString 先截断再写入，若同一对象的并发
    // 写入共用固定名临时文件，前一次上传的原生读取可能恰好落在截断与
    // 写入之间，把 0 字节内容传上 OSS（曾产生空清单对象）。
    final file = File(
        '${Directory.systemTemp.path}/$path.manifest.${DateTime.now().microsecondsSinceEpoch}-${_uploadTextSeq++}');
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
    try {
      // taskId 必须唯一：原生侧同名传输会先取消旧任务，相册清单存在
      // 并发更新（删除清理与还原合并同时触发），固定 taskId 会导致
      // 其中一方被误取消。
      await uploadFile(
        path,
        file.path,
        session,
        taskId: 'manifest-$path-${DateTime.now().microsecondsSinceEpoch}',
      );
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<List<int>> download(
    String path,
    UserSession session, {
    int? maxBytes,
  }) async {
    await _ensureConfigured(session);
    return _platform(
      () => _native.getObjectBytes(
        key: path,
        maxBytes: maxBytes ?? session.constraints.textPreviewMaxBytes,
      ),
    );
  }

  Future<void> downloadToFile(
    String path,
    UserSession session,
    File target, {
    required String taskId,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {
    await _ensureConfigured(session);
    await _withProgress(
      taskId: taskId,
      isCanceled: isCanceled,
      onProgress: onProgress,
      operation: () => _native.downloadFile(
        taskId: taskId,
        key: path,
        localPath: target.path,
      ),
    );
  }

  Future<void> downloadToMediaStore(
    String path,
    UserSession session, {
    required String displayName,
    required String collection,
    required String taskId,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {
    await _ensureConfigured(session);
    await _withProgress(
      taskId: taskId,
      isCanceled: isCanceled,
      onProgress: onProgress,
      operation: () => _native.downloadFile(
        taskId: taskId,
        key: path,
        localPath: '',
        mediaStoreCollection: collection,
        displayName: displayName,
      ),
    );
  }

  Future<void> downloadToDirectoryUri(
    String path,
    UserSession session, {
    required String directoryUri,
    required String displayName,
    required String taskId,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {
    await _ensureConfigured(session);
    await _withProgress(
      taskId: taskId,
      isCanceled: isCanceled,
      onProgress: onProgress,
      operation: () => _native.downloadFile(
        taskId: taskId,
        key: path,
        localPath: '',
        directoryUri: directoryUri,
        displayName: displayName,
      ),
    );
  }

  /// 生成 GetObject 预签名 URL（纯本地签名）。URL 等同于访问凭证，
  /// 仅限内存中短期使用（如流式播放），不得落盘或写日志。
  Future<String> presignGetObjectUrl(
    String path,
    UserSession session, {
    Duration expires = const Duration(hours: 1),
  }) async {
    await _ensureConfigured(session);
    return _platform(
      () => _native.presignGetObjectUrl(path, expires: expires),
    );
  }

  /// 生成通用对象预签名 URL（复用视频预签名机制），供文档流式下载、
  /// 音频流式播放等场景使用。
  Future<String> presignObjectUrl(
    String path,
    UserSession session, {
    Duration expires = const Duration(hours: 1),
  }) =>
      presignGetObjectUrl(path, session, expires: expires);

  /// 通过预签名 URL 将对象流式下载到本地文件（不经原生 SDK 整段载入
  /// 内存）。支持进度回调与取消；取消或失败时调用方负责清理目标文件。
  Future<void> streamDownloadToFile(
    String path,
    UserSession session,
    File target, {
    Duration expires = const Duration(hours: 1),
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    bool Function()? isCanceled,
  }) async {
    final url = await presignObjectUrl(path, session, expires: expires);
    final client = http.Client();
    try {
      if (isCanceled?.call() == true) {
        throw const TransferCanceledException();
      }
      final response = await client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) {
        throw AppError(
          '文档下载失败（HTTP ${response.statusCode}）',
          code: 'OSS_DOCUMENT_DOWNLOAD_FAILED',
        );
      }
      final total = response.contentLength;
      var received = 0;
      final sink = target.openWrite();
      var sinkClosed = false;
      Future<void> closeSink() async {
        if (sinkClosed) return;
        sinkClosed = true;
        await sink.close();
      }

      try {
        await for (final chunk in response.stream) {
          if (isCanceled?.call() == true) {
            await closeSink();
            throw const TransferCanceledException();
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
        await closeSink();
      } catch (error) {
        await closeSink();
        rethrow;
      }
    } finally {
      client.close();
    }
  }

  /// 读取对象指定字节范围（Range 请求），供大文本分段加载使用。
  Future<List<int>> getObjectRange(
    String path,
    UserSession session, {
    required int startByte,
    required int endByte,
  }) =>
      _getObjectRange(
        path,
        session,
        startByte: startByte,
        endByte: endByte,
      );

  Future<void> copy(String from, String to, UserSession session) async {
    await _ensureConfigured(session);
    await _platform(() => _native.copyObject(from: from, to: to));
  }

  Future<void> cancelTransfer(String taskId) =>
      _platform(() => _native.cancelTransfer(taskId));

  Future<void> _withProgress({
    required String taskId,
    required Future<void> Function() operation,
    required void Function(int transferredBytes, int totalBytes) onProgress,
    bool Function()? isCanceled,
  }) async {
    var cancelRequested = false;
    var lastTransferred = 0;
    final subscription = _native.progressEvents
        .where((event) => event.taskId == taskId)
        .listen((event) {
      if (isCanceled?.call() == true) {
        if (!cancelRequested) {
          cancelRequested = true;
          unawaited(_native.cancelTransfer(taskId));
        }
        return;
      }
      if (event.transferredBytes < lastTransferred) return;
      lastTransferred = event.transferredBytes;
      onProgress(lastTransferred, event.totalBytes);
    });
    try {
      if (isCanceled?.call() == true) throw const TransferCanceledException();
      // 传输任务按字节有进度回调，不设整体超时，仅依赖 SDK 的
      // 连接/读超时判定连接失效。
      await _platform(operation, timeout: null);
      if (isCanceled?.call() == true) throw const TransferCanceledException();
    } finally {
      await subscription.cancel();
    }
  }
}
