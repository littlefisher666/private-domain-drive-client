import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:private_domain_oss/private_domain_oss.dart';

import '../../../core/errors/app_error.dart';
import '../../auth/domain/user_session.dart';
import '../domain/file_item.dart';

/// 统一 OSS 基础设施入口。所有对象协议均由当前平台的阿里云官方 SDK执行。
class OssClient {
  OssClient({PrivateDomainOss? native})
      : _native = native ?? PrivateDomainOss();

  final PrivateDomainOss _native;
  final Set<String> _reportedErrorSignatures = <String>{};
  String? _configuredSession;

  Future<void> configureSession(UserSession session) =>
      _ensureConfigured(session);

  Future<List<FileItem>> list(String path, UserSession session) async {
    await _ensureConfigured(session);
    final prefix = _dir(path);
    final page = await _platform(
      () => _native.listObjects(prefix: prefix, delimiter: '/'),
    );
    return <FileItem>[
      for (final key in page.commonPrefixes)
        if (key != prefix)
          FileItem(
            path: key,
            name: key.substring(prefix.length).replaceFirst(RegExp(r'/$'), ''),
            isDirectory: true,
          ),
      for (final object in page.objects)
        if (object.key != prefix &&
            !object.key.substring(prefix.length).contains('/'))
          FileItem(
            path: object.key,
            name: object.key.substring(prefix.length),
            isDirectory: false,
            size: object.size,
            updatedAt: object.lastModifiedMilliseconds == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    object.lastModifiedMilliseconds!,
                    isUtc: true,
                  ).toLocal(),
          ),
    ];
  }

  Future<void> createFolder(String path, UserSession session) async {
    await _ensureConfigured(session);
    await _platform(() => _native.putEmptyObject(_dir(path)));
  }

  Future<void> delete(String path, UserSession session) async {
    await _ensureConfigured(session);
    await _platform(() => _native.deleteObject(path));
  }

  Future<List<String>> listAllObjectKeys(
    String path,
    UserSession session,
  ) async {
    await _ensureConfigured(session);
    final keys = <String>[];
    String? marker;
    do {
      final page = await _platform(
        () => _native.listObjects(
          prefix: _dir(path),
          marker: marker,
          maxKeys: 1000,
        ),
      );
      keys.addAll(page.objects.map((object) => object.key));
      marker = page.isTruncated ? page.nextMarker : null;
      if (page.isTruncated && (marker == null || marker.isEmpty)) {
        throw AppError('OSS 分页响应缺少下一页标识', code: 'OSS_INVALID_RESPONSE');
      }
    } while (marker != null && marker.isNotEmpty);
    return keys;
  }

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

  Future<List<int>> download(String path, UserSession session) async {
    await _ensureConfigured(session);
    return _platform(
      () => _native.getObjectBytes(
        key: path,
        maxBytes: session.constraints.textPreviewMaxBytes,
      ),
    );
  }

  Future<List<int>> downloadThumbnail(
    String path,
    UserSession session, {
    int width = ImageThumbnailSpec.size,
    int height = ImageThumbnailSpec.size,
  }) async {
    if (width <= 0 || height <= 0 || width > 1024 || height > 1024) {
      throw ArgumentError('缩略图尺寸必须在 1 到 1024 之间');
    }
    return _getProcessedObject(
      path,
      session,
      maxBytes: 4 * 1024 * 1024,
      process: ImageThumbnailSpec.process(width: width, height: height),
    );
  }

  /// 读取用于详情页展示的图片预览，仍由 OSS 图片处理压缩原图尺寸。
  Future<List<int>> downloadImagePreview(
    String path,
    UserSession session, {
    int width = ImageThumbnailSpec.previewSize,
    int height = ImageThumbnailSpec.previewSize,
  }) async {
    if (width <= 0 || height <= 0 || width > 2048 || height > 2048) {
      throw ArgumentError('图片预览尺寸必须在 1 到 2048 之间');
    }
    return _getProcessedObject(
      path,
      session,
      maxBytes: 8 * 1024 * 1024,
      process: ImageThumbnailSpec.process(width: width, height: height),
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

  Future<void> copy(String from, String to, UserSession session) async {
    await _ensureConfigured(session);
    await _platform(() => _native.copyObject(from: from, to: to));
  }

  Future<void> cancelTransfer(String taskId) =>
      _platform(() => _native.cancelTransfer(taskId));

  Future<void> clearConfiguration() async {
    _configuredSession = null;
    await _platform(_native.clearConfiguration);
  }

  Future<void> _ensureConfigured(UserSession session,
      {bool force = false}) async {
    final config = session.ossConfig ??
        (throw AppError('会话缺少 OSS 配置', code: 'OSS_CONFIG_MISSING'));
    final credentials = session.credentials ??
        (throw AppError('会话缺少 OSS 临时凭证', code: 'OSS_CREDENTIALS_MISSING'));
    final fingerprint = <Object>[
      config.endpoint,
      config.region,
      config.bucket,
      credentials.accessKeyId,
      credentials.securityToken,
      credentials.expiration.toUtc().millisecondsSinceEpoch,
    ].join('|');
    if (!force && _configuredSession == fingerprint) return;
    await _platform(
      () => _native.configure(
        endpoint: config.endpoint,
        region: config.region,
        bucket: config.bucket,
        accessKeyId: credentials.accessKeyId,
        accessKeySecret: credentials.accessKeySecret,
        securityToken: credentials.securityToken,
        expirationMilliseconds:
            credentials.expiration.toUtc().millisecondsSinceEpoch,
      ),
    );
    _configuredSession = fingerprint;
  }

  Future<List<int>> _getProcessedObject(
    String path,
    UserSession session, {
    required int maxBytes,
    required String process,
  }) async {
    Future<List<int>> request() => _platform(
          () => _native.getObjectBytes(
            key: path,
            maxBytes: maxBytes,
            process: process,
          ),
        );

    await _ensureConfigured(session, force: true);
    try {
      return await request();
    } on AppError catch (error) {
      if (error.code != 'OSS_INVALIDREQUEST') rethrow;
      _configuredSession = null;
      await _ensureConfigured(session);
      return request();
    }
  }

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
      await _platform(operation);
      if (isCanceled?.call() == true) throw const TransferCanceledException();
    } finally {
      await subscription.cancel();
    }
  }

  Future<T> _platform<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on PlatformException catch (error) {
      if (error.code == OssErrorCode.canceled.name) {
        throw const TransferCanceledException();
      }
      final details = error.details;
      final ossCode = details is Map ? details['ossCode'] : null;
      final sdkCode = details is Map ? details['sdkCode'] : null;
      final bridgeCode = details is Map ? details['bridgeCode'] : null;
      final nativeErrorType =
          details is Map ? details['nativeErrorType'] : null;
      final statusCode = details is Map ? details['statusCode'] : null;
      final errorSignature = <Object?>[
        error.code,
        ossCode,
        sdkCode,
        bridgeCode,
        nativeErrorType,
        statusCode,
      ].join('|');
      if (kDebugMode && _reportedErrorSignatures.add(errorSignature)) {
        debugPrint(
          'OSS 请求失败：${error.code}（ossCode: ${ossCode ?? '-'}，sdkCode: ${sdkCode ?? '-'}，bridgeCode: ${bridgeCode ?? '-'}，nativeType: ${nativeErrorType ?? '-'}，状态码: ${statusCode ?? '-'}）',
        );
      }
      const messages = <String, String>{
        'credentialExpired': 'OSS 临时凭证已过期',
        'accessDenied': '没有权限执行该 OSS 操作',
        'notFound': 'OSS 对象不存在',
        'networkUnavailable': '网络连接不可用',
        'invalidRequest': 'OSS 请求参数无效',
        'serviceError': 'OSS 服务请求失败',
        'unknown': 'OSS 操作失败',
      };
      throw AppError(
        messages[error.code] ?? 'OSS 操作失败',
        code: 'OSS_${error.code.toUpperCase()}',
      );
    } on TransferCanceledException {
      rethrow;
    } on AppError {
      rethrow;
    }
  }

  String _dir(String value) => value.endsWith('/') ? value : '$value/';
}

class TransferCanceledException implements Exception {
  const TransferCanceledException();
}

class BatchDeleteResult {
  const BatchDeleteResult({
    this.deletedPaths = const <String>[],
    this.failedPaths = const <String>[],
  });

  final List<String> deletedPaths;
  final List<String> failedPaths;
}
