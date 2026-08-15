import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/errors/app_error.dart';
import '../../auth/domain/user_session.dart';
import '../domain/file_item.dart';

/// 使用 FC 下发的 STS 临时凭证直连 OSS，不经过 FC 中转文件内容。
class OssClient {
  OssClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static const _multipartPartSize = 5 * 1024 * 1024;

  final http.Client _http;

  Future<List<FileItem>> list(String path, UserSession session) async {
    final config = _config(session);
    final prefix = _dir(path);
    final response = await _request(
      method: 'GET',
      config: config,
      credentials: session.credentials!,
      query: <String, String>{'prefix': prefix, 'delimiter': '/'},
    );
    _log('ListObjects ${response.statusCode} ${response.request?.url}');
    _check(response);
    // OSS 的 XML 响应可能不声明 charset，http 默认解码会把中文解析成乱码；
    // OSS 响应规范使用 UTF-8，因此统一从原始字节按 UTF-8 解码。
    final xml = utf8.decode(response.bodyBytes, allowMalformed: true);
    final items = <FileItem>[];
    for (final value in _tags(xml, 'CommonPrefixes')) {
      final key = _xmlValue(value, 'Prefix');
      if (key.isEmpty || key == prefix) continue;
      final name = key.substring(prefix.length).replaceFirst(RegExp(r'/$'), '');
      items.add(FileItem(path: key, name: name, isDirectory: true));
    }
    for (final value in _tags(xml, 'Contents')) {
      final key = _xmlValue(value, 'Key');
      if (key.isEmpty || key == prefix) continue;
      final name = key.substring(prefix.length);
      if (name.contains('/')) continue;
      final size = int.tryParse(_xmlValue(value, 'Size'));
      // OSS 的 LastModified 使用 UTC（例如带 Z 的 ISO 8601 时间），列表展示应使用
      // 设备本地时区；当前 macOS 为 Asia/Shanghai 时会显示东八区时间。
      final modified =
          DateTime.tryParse(_xmlValue(value, 'LastModified'))?.toLocal();
      items.add(FileItem(
          path: key,
          name: name,
          isDirectory: false,
          size: size,
          updatedAt: modified));
    }
    return items;
  }

  Future<void> createFolder(String path, UserSession session) async {
    final config = _config(session);
    final response = await _request(
        method: 'PUT',
        config: config,
        credentials: session.credentials!,
        objectKey: _dir(path),
        body: const <int>[]);
    _check(response);
  }

  Future<void> delete(String path, UserSession session) async {
    final config = _config(session);
    final response = await _request(
        method: 'DELETE',
        config: config,
        credentials: session.credentials!,
        objectKey: path);
    _check(response);
  }

  /// 列出指定前缀下的全部对象键，供目录递归删除使用。
  Future<List<String>> listAllObjectKeys(
    String path,
    UserSession session,
  ) async {
    final config = _config(session);
    final prefix = _dir(path);
    final keys = <String>[];
    String? marker;
    do {
      final query = <String, String>{
        'prefix': prefix,
        'max-keys': '1000',
        if (marker != null) 'marker': marker,
      };
      final response = await _request(
        method: 'GET',
        config: config,
        credentials: session.credentials!,
        query: query,
      );
      _check(response);
      final xml = utf8.decode(response.bodyBytes, allowMalformed: true);
      keys.addAll(_tags(xml, 'Contents')
          .map((value) => _xmlValue(value, 'Key'))
          .where((key) => key.isNotEmpty));
      final truncated = _xmlValue(xml, 'IsTruncated').toLowerCase() == 'true';
      marker = truncated ? _xmlValue(xml, 'NextMarker') : null;
      if (truncated && (marker == null || marker.isEmpty)) {
        marker = keys.isEmpty ? null : keys.last;
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
    final config = _config(session);
    final body = utf8.encode(
      '<Delete>'
      '${requested.map((path) => '<Object><Key>${_escapeXml(path)}</Key></Object>').join()}'
      '<Quiet>false</Quiet>'
      '</Delete>',
    );
    final response = await _request(
      method: 'POST',
      config: config,
      credentials: session.credentials!,
      rawQuery: 'delete',
      body: body,
    );
    _check(response);
    final xml = utf8.decode(response.bodyBytes, allowMalformed: true);
    final deleted = _tags(xml, 'Deleted')
        .map((value) => _xmlValue(value, 'Key'))
        .where((key) => key.isNotEmpty)
        .toSet();
    final failed = _tags(xml, 'Error')
        .map((value) => _xmlValue(value, 'Key'))
        .where((key) => key.isNotEmpty)
        .toSet();
    // 部分 OSS 配置在成功时可能省略 Deleted 明细；此时没有错误即视为全部成功。
    final success = deleted.isEmpty && failed.isEmpty ? requested : deleted;
    return BatchDeleteResult(
      deletedPaths: success.toList(growable: false),
      failedPaths: failed.toList(growable: false),
    );
  }

  Future<void> upload(String path, List<int> bytes, UserSession session) async {
    if (bytes.length >= session.constraints.multipartUploadThresholdBytes) {
      await _multipartUpload(path, bytes, session);
      return;
    }

    final config = _config(session);
    final response = await _request(
      method: 'PUT',
      config: config,
      credentials: session.credentials!,
      objectKey: path,
      body: bytes,
    );
    _check(response);
  }

  Future<void> _multipartUpload(
    String path,
    List<int> bytes,
    UserSession session,
  ) async {
    final config = _config(session);
    final credentials = session.credentials!;
    final initiateResponse = await _request(
      method: 'POST',
      config: config,
      credentials: credentials,
      objectKey: path,
      rawQuery: 'uploads',
    );
    _check(initiateResponse);
    final uploadId = _xmlValue(
      utf8.decode(initiateResponse.bodyBytes, allowMalformed: true),
      'UploadId',
    );
    if (uploadId.isEmpty) {
      throw AppError('OSS 初始化分片上传失败：缺少 UploadId',
          code: 'OSS_MULTIPART_INIT_FAILED');
    }

    final parts = <_MultipartPart>[];
    try {
      for (var offset = 0, partNumber = 1;
          offset < bytes.length;
          offset += _multipartPartSize, partNumber++) {
        final end = (offset + _multipartPartSize).clamp(0, bytes.length);
        final part = bytes.sublist(offset, end);
        final response = await _request(
          method: 'PUT',
          config: config,
          credentials: credentials,
          objectKey: path,
          rawQuery:
              'partNumber=$partNumber&uploadId=${Uri.encodeQueryComponent(uploadId)}',
          body: part,
        );
        _check(response);
        final eTag = response.headers['etag'];
        if (eTag == null || eTag.isEmpty) {
          throw AppError('OSS 上传分片失败：缺少 ETag',
              code: 'OSS_MULTIPART_PART_FAILED');
        }
        parts.add(_MultipartPart(number: partNumber, eTag: eTag));
      }

      final completeBody = utf8.encode(
        '<CompleteMultipartUpload>'
        '${parts.map((part) => '<Part><PartNumber>${part.number}</PartNumber><ETag>${part.eTag}</ETag></Part>').join()}'
        '</CompleteMultipartUpload>',
      );
      final completeResponse = await _request(
        method: 'POST',
        config: config,
        credentials: credentials,
        objectKey: path,
        rawQuery: 'uploadId=${Uri.encodeQueryComponent(uploadId)}',
        body: completeBody,
      );
      _check(completeResponse);
    } catch (_) {
      try {
        final abortResponse = await _request(
          method: 'DELETE',
          config: config,
          credentials: credentials,
          objectKey: path,
          rawQuery: 'uploadId=${Uri.encodeQueryComponent(uploadId)}',
        );
        _check(abortResponse);
      } catch (_) {
        // 保留原始上传错误，避免中止失败掩盖真正的失败原因。
      }
      rethrow;
    }
  }

  Future<List<int>> download(String path, UserSession session) async {
    final config = _config(session);
    final response = await _request(
        method: 'GET',
        config: config,
        credentials: session.credentials!,
        objectKey: path);
    _check(response);
    return response.bodyBytes;
  }

  /// 将 OSS 对象直接写入临时文件，避免批量下载时把完整文件保留在内存中。
  Future<void> downloadToFile(
    String path,
    UserSession session,
    File target, {
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {
    final config = _config(session);
    final request = _streamRequest(
      method: 'GET',
      config: config,
      credentials: session.credentials!,
      objectKey: path,
    );
    final response = await _http.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _check(await http.Response.fromStream(response));
      return;
    }

    await target.parent.create(recursive: true);
    final sink = target.openWrite();
    var received = 0;
    final total = response.contentLength;
    try {
      await for (final chunk in response.stream) {
        if (isCanceled()) {
          throw const TransferCanceledException();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      if (isCanceled()) {
        throw const TransferCanceledException();
      }
    } finally {
      await sink.close();
    }
  }

  Future<void> copy(String from, String to, UserSession session) async {
    final config = _config(session);
    // OSS 要求 x-oss-copy-source 的对象路径进行 URL 编码；逐段编码可保留
    // 路径分隔符，否则中文、空格等文件名会在请求发出前被 HTTP 客户端拒绝。
    final encodedSource = from.split('/').map(Uri.encodeComponent).join('/');
    final response = await _request(
      method: 'PUT',
      config: config,
      credentials: session.credentials!,
      objectKey: to,
      extraHeaders: <String, String>{
        'x-oss-copy-source': '/${config.bucket}/$encodedSource',
      },
    );
    _check(response);
  }

  Uri _uri(
    OssConfig config, {
    String? objectKey,
    Map<String, String>? query,
    String? rawQuery,
  }) {
    final endpoint = config.endpoint.replaceFirst(RegExp(r'^https?://'), '');
    // Uri.https 会对 path 自动进行一次编码，这里不能提前 encodeComponent，
    // 否则中文路径中的 '%' 会被再次编码成 '%25'。
    final path = objectKey == null ? '/' : '/$objectKey';
    if (rawQuery != null) {
      return Uri(
        scheme: 'https',
        host: '${config.bucket}.$endpoint',
        path: path,
        query: rawQuery,
      );
    }
    return Uri.https('${config.bucket}.$endpoint', path, query);
  }

  Future<http.Response> _request(
      {required String method,
      required OssConfig config,
      required StsCredentials credentials,
      String? objectKey,
      Map<String, String>? query,
      String? rawQuery,
      List<int>? body,
      Map<String, String>? extraHeaders}) {
    final uri =
        _uri(config, objectKey: objectKey, query: query, rawQuery: rawQuery);
    _log('$method $uri');
    final date = HttpDate.format(DateTime.now().toUtc());
    // OSS 虚拟主机请求的签名资源仍需包含 Bucket 名称。
    // prefix/delimiter 是 ListObjects 参数，不属于 OSS 签名子资源。
    final objectPath = objectKey == null ? '' : '/$objectKey';
    final canonicalResource = objectKey == null
        ? '/${config.bucket}/'
        : '/${config.bucket}$objectPath';
    final signedResource =
        rawQuery == null ? canonicalResource : '$canonicalResource?$rawQuery';
    final contentMd5 =
        body == null ? '' : base64Encode(md5.convert(body).bytes);
    final canonicalHeaders = <String, String>{
      'x-oss-security-token': credentials.securityToken,
      ...?extraHeaders?.entries
          .where((entry) => entry.key.toLowerCase().startsWith('x-oss-'))
          .fold<Map<String, String>>(<String, String>{}, (map, entry) {
        map[entry.key.toLowerCase()] = entry.value.trim();
        return map;
      }),
    };
    final canonicalHeaderText = (canonicalHeaders.keys.toList()..sort())
        .map((key) => '$key:${canonicalHeaders[key]}')
        .join('\n');
    final stringToSign =
        '$method\n$contentMd5\n\n$date\n$canonicalHeaderText\n$signedResource';
    final digest = Hmac(sha1, utf8.encode(credentials.accessKeySecret))
        .convert(utf8.encode(stringToSign));
    final headers = <String, String>{
      'Date': date,
      'x-oss-security-token': credentials.securityToken,
      'Authorization':
          'OSS ${credentials.accessKeyId}:${base64Encode(digest.bytes)}'
    };
    if (body != null) headers['Content-MD5'] = contentMd5;
    if (body != null) headers['Content-Length'] = '${body.length}';
    headers.addAll(extraHeaders ?? const <String, String>{});
    return switch (method) {
      'GET' => _http.get(uri, headers: headers),
      'POST' => _http.post(uri, headers: headers, body: body),
      'PUT' => _http.put(uri, headers: headers, body: body),
      'DELETE' => _http.delete(uri, headers: headers),
      _ => throw AppError('不支持的 OSS 请求', code: 'OSS_METHOD_UNSUPPORTED'),
    };
  }

  http.Request _streamRequest({
    required String method,
    required OssConfig config,
    required StsCredentials credentials,
    required String objectKey,
  }) {
    final uri = _uri(config, objectKey: objectKey);
    final date = HttpDate.format(DateTime.now().toUtc());
    final canonicalHeaders =
        'x-oss-security-token:${credentials.securityToken}';
    final stringToSign = '$method\n\n\n$date\n$canonicalHeaders\n'
        '/${config.bucket}/$objectKey';
    final digest = Hmac(sha1, utf8.encode(credentials.accessKeySecret))
        .convert(utf8.encode(stringToSign));
    return http.Request(method, uri)
      ..headers.addAll(<String, String>{
        'Date': date,
        'x-oss-security-token': credentials.securityToken,
        'Authorization':
            'OSS ${credentials.accessKeyId}:${base64Encode(digest.bytes)}',
      });
  }

  OssConfig _config(UserSession session) =>
      session.ossConfig ??
      (throw AppError('会话缺少 OSS 配置', code: 'OSS_CONFIG_MISSING'));
  String _dir(String value) => value.endsWith('/') ? value : '$value/';
  void _check(http.Response response) {
    _log('response ${response.statusCode} ${response.request?.url}');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code =
          RegExp(r'<Code>([^<]+)</Code>').firstMatch(response.body)?.group(1);
      final requestId = RegExp(r'<RequestId>([^<]+)</RequestId>')
          .firstMatch(response.body)
          ?.group(1);
      _log(
          'error status=${response.statusCode} code=${code ?? 'UNKNOWN'} requestId=${requestId ?? 'UNKNOWN'}');
      final serverString = RegExp(r'<StringToSign>([\s\S]*?)</StringToSign>')
          .firstMatch(response.body)
          ?.group(1)
          ?.replaceFirst(RegExp(r'x-oss-security-token:[^\\n]*'),
              'x-oss-security-token:<redacted>');
      if (serverString != null) _log('server StringToSign=$serverString');
      throw AppError(
          'OSS 请求失败 (${response.statusCode}${code == null ? '' : ' $code'})',
          code: 'OSS_REQUEST_FAILED');
    }
  }

  void _log(String message) {
    if (kDebugMode) debugPrint('[OSS] $message');
  }

  List<String> _tags(String xml, String tag) =>
      RegExp('<$tag>([\\s\\S]*?)</$tag>')
          .allMatches(xml)
          .map((m) => m.group(1)!)
          .toList();
  String _xmlValue(String xml, String tag) =>
      RegExp('<$tag>([\\s\\S]*?)</$tag>')
          .firstMatch(xml)
          ?.group(1)
          ?.replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>') ??
      '';

  String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

class _MultipartPart {
  const _MultipartPart({required this.number, required this.eTag});

  final int number;
  final String eTag;
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
