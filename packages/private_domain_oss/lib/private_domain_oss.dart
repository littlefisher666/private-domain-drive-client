import 'dart:async';
import 'package:flutter/services.dart';

const _methodChannelName = 'private_domain_oss/methods';
const _eventChannelName = 'private_domain_oss/transfers';

enum OssTransferDirection { upload, download }

enum OssErrorCode {
  credentialExpired,
  accessDenied,
  notFound,
  networkUnavailable,
  canceled,
  invalidRequest,
  serviceError,
  unknown,
}

class OssTransferProgress {
  const OssTransferProgress({
    required this.taskId,
    required this.direction,
    required this.transferredBytes,
    required this.totalBytes,
  });

  final String taskId;
  final OssTransferDirection direction;
  final int transferredBytes;
  final int totalBytes;

  factory OssTransferProgress.fromMap(Map<Object?, Object?> map) {
    return OssTransferProgress(
      taskId: map['taskId']! as String,
      direction: map['direction'] == 'download'
          ? OssTransferDirection.download
          : OssTransferDirection.upload,
      transferredBytes: (map['transferredBytes']! as num).toInt(),
      totalBytes: (map['totalBytes']! as num).toInt(),
    );
  }
}

class OssNativeObject {
  const OssNativeObject({
    required this.key,
    required this.size,
    this.lastModifiedMilliseconds,
    this.etag,
    this.storageClass,
  });

  final String key;
  final int size;
  final int? lastModifiedMilliseconds;
  final String? etag;
  final String? storageClass;

  factory OssNativeObject.fromMap(Map<Object?, Object?> map) {
    return OssNativeObject(
      key: map['key']! as String,
      size: (map['size'] as num?)?.toInt() ?? 0,
      lastModifiedMilliseconds:
          (map['lastModifiedMilliseconds'] as num?)?.toInt(),
      etag: map['etag'] as String?,
      storageClass: map['storageClass'] as String?,
    );
  }
}

class OssListPage {
  const OssListPage({
    required this.objects,
    required this.commonPrefixes,
    required this.isTruncated,
    this.nextMarker,
  });

  final List<OssNativeObject> objects;
  final List<String> commonPrefixes;
  final bool isTruncated;
  final String? nextMarker;

  factory OssListPage.fromMap(Map<Object?, Object?> map) {
    return OssListPage(
      objects: (map['objects'] as List<Object?>? ?? const <Object?>[])
          .cast<Map<Object?, Object?>>()
          .map(OssNativeObject.fromMap)
          .toList(growable: false),
      commonPrefixes:
          (map['commonPrefixes'] as List<Object?>? ?? const <Object?>[])
              .cast<String>(),
      isTruncated: map['isTruncated'] == true,
      nextMarker: map['nextMarker'] as String?,
    );
  }
}

class OssDeleteResult {
  const OssDeleteResult({
    required this.deletedKeys,
    required this.failedKeys,
  });

  final List<String> deletedKeys;
  final List<String> failedKeys;

  factory OssDeleteResult.fromMap(Map<Object?, Object?> map) {
    return OssDeleteResult(
      deletedKeys: (map['deletedKeys'] as List<Object?>? ?? const <Object?>[])
          .cast<String>(),
      failedKeys: (map['failedKeys'] as List<Object?>? ?? const <Object?>[])
          .cast<String>(),
    );
  }
}

class PrivateDomainOss {
  PrivateDomainOss({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methods = methodChannel ?? const MethodChannel(_methodChannelName),
        _events = eventChannel ?? const EventChannel(_eventChannelName);

  final MethodChannel _methods;
  final EventChannel _events;
  Stream<OssTransferProgress>? _progress;

  Stream<OssTransferProgress> get progressEvents =>
      _progress ??= _events.receiveBroadcastStream().map((event) =>
          OssTransferProgress.fromMap((event! as Map<Object?, Object?>)));

  Future<void> configure({
    required String endpoint,
    required String region,
    required String bucket,
    required String accessKeyId,
    required String accessKeySecret,
    required String securityToken,
    required int expirationMilliseconds,
  }) {
    return _methods.invokeMethod<void>('configure', <String, Object>{
      'endpoint': endpoint,
      'region': region,
      'bucket': bucket,
      'accessKeyId': accessKeyId,
      'accessKeySecret': accessKeySecret,
      'securityToken': securityToken,
      'expirationMilliseconds': expirationMilliseconds,
    });
  }

  Future<void> clearConfiguration() =>
      _methods.invokeMethod<void>('clearConfiguration');

  Future<OssListPage> listObjects({
    required String prefix,
    String? delimiter,
    String? marker,
    int maxKeys = 1000,
  }) async {
    final result = await _methods.invokeMapMethod<Object?, Object?>(
      'listObjects',
      <String, Object?>{
        'prefix': prefix,
        'delimiter': delimiter,
        'marker': marker,
        'maxKeys': maxKeys,
      },
    );
    return OssListPage.fromMap(result!);
  }

  Future<void> putEmptyObject(String key) => _methods
      .invokeMethod<void>('putEmptyObject', <String, Object>{'key': key});

  Future<void> deleteObject(String key) =>
      _methods.invokeMethod<void>('deleteObject', <String, Object>{'key': key});

  Future<OssDeleteResult> deleteObjects(Iterable<String> keys) async {
    final result = await _methods.invokeMapMethod<Object?, Object?>(
      'deleteObjects',
      <String, Object>{'keys': keys.toList(growable: false)},
    );
    return OssDeleteResult.fromMap(result!);
  }

  Future<void> copyObject({required String from, required String to}) =>
      _methods.invokeMethod<void>('copyObject', <String, Object>{
        'from': from,
        'to': to,
      });

  Future<void> uploadFile({
    required String taskId,
    required String key,
    required String localPath,
    required int multipartThresholdBytes,
  }) =>
      _methods.invokeMethod<void>('uploadFile', <String, Object>{
        'taskId': taskId,
        'key': key,
        'localPath': localPath,
        'multipartThresholdBytes': multipartThresholdBytes,
      });

  Future<void> downloadFile({
    required String taskId,
    required String key,
    required String localPath,
    String? mediaStoreCollection,
    String? displayName,
    String? directoryUri,
  }) =>
      _methods.invokeMethod<void>('downloadFile', <String, Object>{
        'taskId': taskId,
        'key': key,
        'localPath': localPath,
        if (mediaStoreCollection != null)
          'mediaStoreCollection': mediaStoreCollection,
        if (displayName != null) 'displayName': displayName,
        if (directoryUri != null) 'directoryUri': directoryUri,
      });

  Future<Uint8List> getObjectBytes({
    required String key,
    required int maxBytes,
    String? process,
    String? range,
  }) async {
    final data = await _methods.invokeMethod<Uint8List>(
      'getObjectBytes',
      <String, Object?>{
        'key': key,
        'maxBytes': maxBytes,
        'process': process,
        'range': range,
      },
    );
    return data!;
  }

  Future<void> cancelTransfer(String taskId) => _methods.invokeMethod<void>(
        'cancelTransfer',
        <String, Object>{'taskId': taskId},
      );
}
