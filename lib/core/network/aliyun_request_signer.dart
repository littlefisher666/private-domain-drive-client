import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 阿里云函数计算 HTTP Trigger 的 ACS3-HMAC-SHA256 签名。
class AliyunRequestSigner {
  const AliyunRequestSigner({
    required this.accessKeyId,
    required this.accessKeySecret,
    required this.region,
    required this.service,
  });

  final String accessKeyId;
  final String accessKeySecret;
  final String region;
  final String service;

  bool get enabled => accessKeyId.isNotEmpty && accessKeySecret.isNotEmpty;

  Map<String, String> sign({
    required String method,
    required Uri uri,
    required String body,
    DateTime? now,
  }) {
    if (!enabled) return const <String, String>{};
    final time = (now ?? DateTime.now()).toUtc();
    final date = _timestamp(time);
    final headers = <String, String>{
      'x-acs-date': date,
    };

    final canonicalHeaders = headers.keys.toList()..sort();
    final canonicalizedFcHeaders = canonicalHeaders
        .map((key) => '$key:${_normalize(headers[key]!)}\n')
        .join();
    final canonicalRequest = [
      method.toUpperCase(),
      _canonicalUri(uri),
      _canonicalQuery(uri),
      canonicalizedFcHeaders,
      canonicalHeaders.join(';'),
      '',
    ].join('\n');
    final stringToSign = 'ACS3-HMAC-SHA256\n${_sha(canonicalRequest)}';
    final signature = _hex(_mac(utf8.encode(accessKeySecret), stringToSign));
    return <String, String>{
      'x-acs-date': date,
      'Authorization': 'ACS3-HMAC-SHA256 Credential=$accessKeyId,SignedHeaders=${canonicalHeaders.join(';')},Signature=$signature',
    };
  }

  String _canonicalUri(Uri uri) => (uri.path.isEmpty ? '/' : uri.path).replaceAll('$', '%24');

  String _canonicalQuery(Uri uri) {
    final entries = uri.queryParameters.entries.toList()
      ..sort((a, b) {
        final key = a.key.compareTo(b.key);
        return key != 0 ? key : a.value.compareTo(b.value);
      });
    return entries.map((e) => '${_encode(e.key)}=${_encode(e.value)}').join('&');
  }

  String _normalize(String value) => value.trim().replaceAll(RegExp(r'\s+'), ' ');

  String _encode(String value) => Uri.encodeComponent(value)
      .replaceAll('+', '%20')
      .replaceAll('*', '%2A')
      .replaceAll('%7E', '~');

  String _date(DateTime v) => '${v.year.toString().padLeft(4, '0')}${v.month.toString().padLeft(2, '0')}${v.day.toString().padLeft(2, '0')}';
  String _timestamp(DateTime v) => v.toIso8601String().split('.').first + 'Z';
}
