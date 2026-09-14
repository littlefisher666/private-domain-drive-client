import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class ApkDownloadProgress {
  const ApkDownloadProgress({required this.received, required this.total});
  final int received;
  final int? total;
  double? get fraction =>
      total == null || total == 0 ? null : received / total!;
}

class ApkDownloader {
  ApkDownloader({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<bool> hasValidDownload({
    required String sha256Digest,
    required String fileName,
  }) async {
    final target = await downloadedFile(fileName);
    if (!await target.exists()) return false;
    try {
      final digest = await sha256.bind(target.openRead()).first;
      final expected = sha256Digest.replaceFirst('sha256:', '').toLowerCase();
      return digest.toString().toLowerCase() == expected;
    } on Object {
      return false;
    }
  }

  Future<int?> downloadedFileSize(String fileName) async {
    final target = await downloadedFile(fileName);
    if (!await target.exists()) return null;
    return target.length();
  }

  Stream<ApkDownloadProgress> download({
    required Uri url,
    required String sha256Digest,
    required String fileName,
  }) async* {
    final directory = await getTemporaryDirectory();
    final target = File('${directory.path}/$fileName');
    if (await target.exists()) {
      await target.delete();
    }
    final request = http.Request('GET', url);
    final response = await _client.send(request);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('下载更新失败（${response.statusCode}）');
    }
    final digest = AccumulatorSink<Digest>();
    final converter = sha256.startChunkedConversion(digest);
    final output = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        converter.add(chunk);
        output.add(chunk);
        received += chunk.length;
        yield ApkDownloadProgress(
            received: received, total: response.contentLength);
      }
      converter.close();
      await output.close();
      final expected = sha256Digest.replaceFirst('sha256:', '').toLowerCase();
      if (digest.events.single.toString().toLowerCase() != expected) {
        await target.delete();
        throw const FileSystemException('更新包 SHA-256 校验失败');
      }
    } catch (_) {
      await output.close();
      if (await target.exists()) {
        await target.delete();
      }
      rethrow;
    }
  }

  Future<File> downloadedFile(String fileName) async =>
      File('${(await getTemporaryDirectory()).path}/$fileName');
}
