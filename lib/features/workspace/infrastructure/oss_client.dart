import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:private_domain_oss/private_domain_oss.dart';

import '../../../core/errors/app_error.dart';
import '../../auth/domain/user_session.dart';
import '../domain/directory_summary.dart';
import '../domain/file_item.dart';

export '../domain/directory_summary.dart';

part 'oss_client_listing.dart';
part 'oss_client_media.dart';
part 'oss_client_transfer.dart';

/// OssClient 的配置、凭证与会话核心，以及各 part 共用的底层工具方法。
///
/// Dart 不允许把同一个类拆到多个 part 文件，因此按职责拆出的成员以
/// mixin 形式放在 `oss_client_listing.dart`（目录列举与统计）、
/// `oss_client_media.dart`（媒体处理）与 `oss_client_transfer.dart`
/// （上传下载等传输）中，由 [OssClient] 混入，公开 API 与行为不变。
abstract class _OssClientCore {
  _OssClientCore(this._native);

  final PrivateDomainOss _native;
  final Set<String> _reportedErrorSignatures = <String>{};
  String? _configuredSession;

  /// OSS 返回鉴权失败（访问密钥被撤销等）时通知外层引导重新登录。
  void Function()? onCredentialExpired;

  /// 非传输类 OSS 调用的整体超时：超过该时长即向用户提示失败。
  /// 弱网下 DNS 解析阻塞时 SDK 自身的连接/读超时不覆盖解析阶段，
  /// 需要外层统一兜底，避免长时间无反馈的加载转圈。
  static const Duration _requestTimeout = Duration(seconds: 10);

  /// testWidgets（FakeAsync）环境下未 mock 的 platform channel 永远不会
  /// 回复，超时定时器会挂在 fake 时钟上导致测试失败；测试环境不设超时。
  static final bool _timeoutEnabled =
      !Platform.environment.containsKey('FLUTTER_TEST');

  Future<void> _ensureConfigured(UserSession session,
      {bool force = false}) async {
    final config = session.ossConfig ??
        (throw AppError('会话缺少 OSS 配置', code: 'OSS_CONFIG_MISSING'));
    final credentials = session.credentials ??
        (throw AppError('会话缺少 OSS 凭证', code: 'OSS_CREDENTIALS_MISSING'));
    final fingerprint = <Object>[
      config.endpoint,
      config.region,
      config.bucket,
      credentials.accessKeyId,
      credentials.accessKeySecret,
    ].join('|');
    if (!force && _configuredSession == fingerprint) return;
    await _platform(
      () => _native.configure(
        endpoint: config.endpoint,
        region: config.region,
        bucket: config.bucket,
        accessKeyId: credentials.accessKeyId,
        accessKeySecret: credentials.accessKeySecret,
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

  Future<T> _platform<T>(
    Future<T> Function() operation, {
    Duration? timeout = _requestTimeout,
  }) async {
    final effectiveTimeout = _timeoutEnabled ? timeout : null;
    final bounded = effectiveTimeout == null
        ? operation()
        : operation().timeout(
            effectiveTimeout,
            onTimeout: () => throw AppError(
              '请求超时，请检查网络后重试',
              code: 'OSS_REQUEST_TIMEOUT',
            ),
          );
    try {
      return await bounded;
    } on PlatformException catch (error) {
      if (error.code == OssErrorCode.canceled.name) {
        throw const TransferCanceledException();
      }
      final details = error.details;
      final ossCode = details is Map ? details['ossCode'] : null;
      final ossMessage = details is Map ? details['ossMessage'] : null;
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
        final site = StackTrace.current
            .toString()
            .split('\n')
            .skip(1)
            .take(3)
            .join(' <- ');
        debugPrint(
          'OSS 请求失败：${error.code}（ossCode: ${ossCode ?? '-'}，sdkCode: ${sdkCode ?? '-'}，bridgeCode: ${bridgeCode ?? '-'}，nativeType: ${nativeErrorType ?? '-'}，状态码: ${statusCode ?? '-'}）'
          '${ossMessage == null ? '' : '\nOSS 消息: $ossMessage'}\n调用位置: $site',
        );
      }
      const messages = <String, String>{
        'credentialExpired': 'OSS 访问密钥无效，请重新登录',
        'accessDenied': '没有权限执行该 OSS 操作',
        'notFound': 'OSS 对象不存在',
        'networkUnavailable': '网络连接不可用',
        'invalidRequest': 'OSS 请求参数无效',
        'serviceError': 'OSS 服务请求失败',
        'unknown': 'OSS 操作失败',
      };
      if (error.code == OssErrorCode.credentialExpired.name) {
        onCredentialExpired?.call();
      }
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

/// 统一 OSS 基础设施入口。所有对象协议均由当前平台的阿里云官方 SDK执行。
class OssClient extends _OssClientCore
    with _OssClientListing, _OssClientMedia, _OssClientTransfer {
  OssClient({PrivateDomainOss? native}) : super(native ?? PrivateDomainOss());

  Future<void> configureSession(UserSession session) =>
      _ensureConfigured(session);

  Future<void> clearConfiguration() async {
    _configuredSession = null;
    await _platform(_native.clearConfiguration);
  }
}
