import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:private_domain_oss/private_domain_oss.dart';

import '../../../core/errors/app_error.dart';
import '../../auth/domain/user_session.dart';
import '../domain/file_item.dart';

const _jpegExifProbeSizes = <int>[
  2 * 1024,
  4 * 1024,
  8 * 1024,
  16 * 1024,
  32 * 1024,
];

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

  /// 通过 OSS 图片处理读取原图 EXIF；不支持或不含 EXIF 的图片返回 null。
  Future<DateTime?> readImageTakenAt(String path, UserSession session) async {
    try {
      final bytes = await _getProcessedObject(
        path,
        session,
        maxBytes: 128 * 1024,
        process: 'image/exif',
      );
      final value = jsonDecode(utf8.decode(bytes));
      if (value is Map) {
        for (final key in <String>[
          'DateTimeOriginal',
          'DateTimeDigitized',
          'DateTime',
        ]) {
          final raw = _findExifValue(value, key);
          if (raw is! String) continue;
          final parsed = _parseExifDate(raw);
          if (parsed != null) return parsed;
        }
      }
    } catch (_) {
      // 继续使用原始 JPEG 文件头兜底，避免图片处理接口差异影响日期展示。
    }
    final header = <int>[];
    for (final targetSize in _jpegExifProbeSizes) {
      final chunk = await _getObjectRange(
        path,
        session,
        startByte: header.length,
        endByte: targetSize - 1,
      );
      header.addAll(chunk);
      final takenAt = _parseJpegExifTakenAt(header);
      if (takenAt != null) return takenAt;
      // JPEG 的所有 EXIF 都位于 SOS（图像数据开始）之前；已越过该位置
      // 仍未找到日期，即可确定没有可用 EXIF，无需读满最大范围。
      if (_isJpegMetadataComplete(header)) return null;
      // 已到文件末尾仍未读到拍摄日期，无需继续扩大范围。
      if (header.length < targetSize) return null;
    }
    return null;
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

  Future<List<int>> _getObjectRange(
    String path,
    UserSession session, {
    required int startByte,
    required int endByte,
  }) async {
    if (startByte < 0 || endByte < startByte) {
      throw ArgumentError('OSS 范围请求参数无效');
    }
    Future<List<int>> request() => _platform(
          () => _native.getObjectBytes(
            key: path,
            maxBytes: endByte - startByte + 1,
            range: 'bytes=$startByte-$endByte',
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

DateTime? _parseExifDate(String value) {
  // EXIF 常见格式为 2026:09:10 14:30:00，且通常没有时区。
  final normalized = value.trim().replaceFirstMapped(
        RegExp(r'^(\d{4}):(\d{2}):(\d{2})'),
        (match) => '${match[1]}-${match[2]}-${match[3]}',
      );
  return DateTime.tryParse(normalized);
}

Object? _findExifValue(Map<dynamic, dynamic> values, String targetKey) {
  for (final entry in values.entries) {
    if (entry.key == targetKey) return entry.value;
    if (entry.value is Map) {
      final nested =
          _findExifValue(entry.value as Map<dynamic, dynamic>, targetKey);
      if (nested != null) return nested;
    }
  }
  return null;
}

DateTime? _parseJpegExifTakenAt(List<int> bytes) {
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return null;
  var offset = 2;
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] != 0xff) {
      offset++;
      continue;
    }
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) return null;
    final marker = bytes[offset++];
    if (marker == 0xd9 || marker == 0xda) return null;
    if ((marker >= 0xd0 && marker <= 0xd7) || marker == 0x01) continue;
    if (offset + 2 > bytes.length) return null;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) return null;
    if (marker == 0xe1 &&
        length >= 8 &&
        bytes[offset + 2] == 0x45 &&
        bytes[offset + 3] == 0x78 &&
        bytes[offset + 4] == 0x69 &&
        bytes[offset + 5] == 0x66 &&
        bytes[offset + 6] == 0 &&
        bytes[offset + 7] == 0) {
      return _parseTiffExifDate(bytes, offset + 8, offset + length);
    }
    offset += length;
  }
  return null;
}

bool _isJpegMetadataComplete(List<int> bytes) {
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return true;
  var offset = 2;
  while (offset + 2 <= bytes.length) {
    if (bytes[offset] != 0xff) return false;
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) return false;
    final marker = bytes[offset++];
    // SOS 之后是压缩图像数据，EXIF 不会再出现。
    if (marker == 0xda || marker == 0xd9) return true;
    if ((marker >= 0xd0 && marker <= 0xd7) || marker == 0x01) continue;
    if (offset + 2 > bytes.length) return false;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) return false;
    offset += length;
  }
  return false;
}

DateTime? _parseTiffExifDate(List<int> bytes, int start, int end) {
  if (start + 8 > end) return null;
  final littleEndian = bytes[start] == 0x49 && bytes[start + 1] == 0x49;
  final bigEndian = bytes[start] == 0x4d && bytes[start + 1] == 0x4d;
  if (!littleEndian && !bigEndian) return null;

  int read16(int offset) {
    if (offset + 2 > end) return -1;
    return littleEndian
        ? bytes[offset] | (bytes[offset + 1] << 8)
        : (bytes[offset] << 8) | bytes[offset + 1];
  }

  int read32(int offset) {
    if (offset + 4 > end) return -1;
    if (littleEndian) {
      return bytes[offset] |
          (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 24);
    }
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  String? readAscii(int entry, int count) {
    final valueOffset = count <= 4 ? entry + 8 : start + read32(entry + 8);
    if (valueOffset < start || valueOffset + count > end) return null;
    return ascii
        .decode(bytes.sublist(valueOffset, valueOffset + count),
            allowInvalid: true)
        .replaceFirst(RegExp(r'\x00.*$'), '');
  }

  int? exifOffset;
  String? dateTime;
  void scanIfd(int ifdOffset, {bool exif = false}) {
    final count = read16(ifdOffset);
    if (count < 0 || ifdOffset + 2 + count * 12 > end) return;
    for (var index = 0; index < count; index++) {
      final entry = ifdOffset + 2 + index * 12;
      final tag = read16(entry);
      final type = read16(entry + 2);
      final valueCount = read32(entry + 4);
      if (tag == 0x8769 && type == 4 && valueCount == 1) {
        exifOffset = start + read32(entry + 8);
      }
      if ((exif && (tag == 0x9003 || tag == 0x9004)) ||
          (!exif && tag == 0x0132)) {
        if (type == 2 && valueCount > 0) {
          dateTime ??= readAscii(entry, valueCount);
        }
      }
    }
  }

  final firstIfd = start + read32(start + 4);
  scanIfd(firstIfd);
  if (exifOffset != null) scanIfd(exifOffset!, exif: true);
  return dateTime == null ? null : _parseExifDate(dateTime!);
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
