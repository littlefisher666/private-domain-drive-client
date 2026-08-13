import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../../core/errors/app_error.dart';
import '../domain/user_session.dart';

/// Lightweight Aliyun STS AssumeRole client (RPC style).
class AliyunStsClient {
  AliyunStsClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  Future<StsCredentials> assumeRole(StsBrokerCredentials broker) async {
    if (broker.accessKeyId.isEmpty || broker.accessKeySecret.isEmpty) {
      throw AppError('STS broker credentials missing', code: 'STS_BROKER_MISSING');
    }
    if (broker.roleArn.isEmpty) {
      throw AppError('STS roleArn missing', code: 'STS_ROLE_MISSING');
    }

    final endpoint = broker.endpoint.replaceFirst(RegExp(r'^https?://'), '');
    final params = <String, String>{
      'Format': 'JSON',
      'Version': '2015-04-01',
      'AccessKeyId': broker.accessKeyId,
      'SignatureMethod': 'HMAC-SHA1',
      'SignatureVersion': '1.0',
      'SignatureNonce': DateTime.now().microsecondsSinceEpoch.toString(),
      'Timestamp': _formatTimestamp(DateTime.now().toUtc()),
      'Action': 'AssumeRole',
      'RoleArn': broker.roleArn,
      'RoleSessionName': broker.roleSessionName,
      'DurationSeconds': broker.durationSeconds.toString(),
    };
    if (broker.policy.trim().isNotEmpty) {
      params['Policy'] = broker.policy;
    }

    params['Signature'] = _sign('GET', params, broker.accessKeySecret);

    final uri = Uri.https(endpoint, '/', params);
    final response = await _http.get(uri);
    Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw AppError(
        'Invalid STS response (${response.statusCode})',
        code: 'STS_BAD_RESPONSE',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = (body['Message'] ?? body['message'] ?? response.body).toString();
      throw AppError(message, code: 'STS_ASSUME_FAILED');
    }

    final credentials = body['Credentials'] as Map<String, dynamic>?;
    if (credentials == null) {
      throw AppError('STS response missing Credentials', code: 'STS_BAD_RESPONSE');
    }

    return StsCredentials(
      accessKeyId: (credentials['AccessKeyId'] ?? '').toString(),
      accessKeySecret: (credentials['AccessKeySecret'] ?? '').toString(),
      securityToken: (credentials['SecurityToken'] ?? '').toString(),
      expiration: parseApiDateTime((credentials['Expiration'] ?? '').toString()),
    );
  }

  String _sign(String method, Map<String, String> params, String accessKeySecret) {
    final sortedKeys = params.keys.toList()..sort();
    final canonical = sortedKeys
        .map((key) => '${_percentEncode(key)}=${_percentEncode(params[key]!)}')
        .join('&');
    final stringToSign =
        '$method&${_percentEncode('/')}&${_percentEncode(canonical)}';
    final hmac = Hmac(sha1, utf8.encode('$accessKeySecret&'));
    final digest = hmac.convert(utf8.encode(stringToSign));
    return base64Encode(digest.bytes);
  }

  String _formatTimestamp(DateTime utc) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${two(utc.month)}-${two(utc.day)}T'
        '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
  }

  String _percentEncode(String value) {
    return Uri.encodeComponent(value)
        .replaceAll('+', '%20')
        .replaceAll('*', '%2A')
        .replaceAll('%7E', '~');
  }
}
