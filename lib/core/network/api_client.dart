import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import '../errors/app_error.dart';
import '../../features/auth/domain/user_session.dart';
import 'aliyun_request_signer.dart';

class ApiClient {
  ApiClient({
    http.Client? httpClient,
    String? baseUrl,
  })  : _http = httpClient ?? http.Client(),
        _baseUrl = (baseUrl ?? AppConstants.fcBaseUrl).replaceAll(RegExp(r'/$'), ''),
        _signer = const AliyunRequestSigner(
          accessKeyId: AppConstants.fcAccessKeyId,
          accessKeySecret: AppConstants.fcAccessKeySecret,
          region: AppConstants.fcRegion,
          service: AppConstants.fcService,
          securityToken: AppConstants.fcSecurityToken,
        );

  final http.Client _http;
  final String _baseUrl;
  final AliyunRequestSigner _signer;

  Future<UserSession> bootstrapSession({
    required String account,
    required String password,
    required String platform,
    required String appVersion,
  }) async {
    final payload = await _postJson(
      '/api/v1/session/bootstrap',
      body: <String, dynamic>{
        'account': account,
        'password': password,
        'platform': platform,
        'appVersion': appVersion,
      },
    );

    final data = payload['data'];
    if (data is! Map<String, dynamic>) {
      throw AppError('Bootstrap response missing data', code: 'BAD_RESPONSE');
    }

    final user = data['user'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final oss = data['oss'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final credentials = data['credentials'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final stsBroker = data['stsBroker'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final capabilities = data['capabilities'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final constraints = data['constraints'] as Map<String, dynamic>? ?? const <String, dynamic>{};

    final rootPrefix = (oss['rootPrefix'] ?? 'shared/').toString();
    return UserSession(
      userId: (user['userId'] ?? account).toString(),
      account: (user['account'] ?? account).toString(),
      displayName: (user['displayName'] ?? account).toString(),
      role: (user['role'] ?? 'member').toString(),
      capabilities: Capabilities.fromJson(capabilities),
      rootPrefix: rootPrefix,
      ossConfig: OssConfig.fromJson(oss),
      credentials: StsCredentials.fromJson(credentials),
      stsBroker: StsBrokerCredentials.fromJson(stsBroker),
      constraints: ClientConstraints.fromJson(constraints),
      authMode: SessionAuthMode.remote,
    );
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    http.Response response;
    try {
      final encodedBody = jsonEncode(body);
      final headers = <String, String>{'accept': 'application/json'};
      if (AppConstants.fcSignRequests) {
        if (!_signer.enabled) {
          throw AppError(
            '缺少 FC 请求签名凭证，请通过 FC_ACCESS_KEY_ID / FC_ACCESS_KEY_SECRET 注入',
            code: 'SIGNING_CONFIG_MISSING',
          );
        }
        headers.addAll(_signer.sign(
          method: 'POST',
          uri: uri,
          body: encodedBody,
        ));
      }
      headers['content-type'] = 'application/json; charset=utf-8';
      response = await _http
          .post(
            uri,
            headers: headers,
            body: encodedBody,
          )
          .timeout(const Duration(seconds: 20));
    } on AppError {
      rethrow;
    } catch (error) {
      throw AppError('无法连接服务: $error', code: 'NETWORK_ERROR');
    }

    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw AppError(
        '服务返回异常 (${response.statusCode})',
        code: 'BAD_RESPONSE',
      );
    }

    final code = (payload['code'] ?? '').toString();
    if (response.statusCode >= 200 && response.statusCode < 300 && code == 'OK') {
      return payload;
    }

    throw AppError(
      (payload['message'] ?? '请求失败').toString(),
      code: code.isEmpty ? 'HTTP_${response.statusCode}' : code,
    );
  }
}
