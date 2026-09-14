import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, this.digest});
  final String name;
  final String url;
  final String? digest;
}

class GithubRelease {
  const GithubRelease(
      {required this.version, required this.notes, required this.assets});
  final String version;
  final String notes;
  final List<ReleaseAsset> assets;

  factory GithubRelease.fromJson(Map<String, dynamic> json) {
    final assets = json['assets'] as Map<String, dynamic>;
    return GithubRelease(
      version: (json['version'] as String).replaceFirst(RegExp(r'^v'), ''),
      notes: (json['notes'] as String?) ?? '',
      assets: assets.values
          .cast<Map<String, dynamic>>()
          .map(
            (asset) => ReleaseAsset(
              name: asset['name'] as String,
              url: asset['url'] as String,
              digest: asset['digest'] as String?,
            ),
          )
          .toList(),
    );
  }
}

class GithubReleaseClient {
  GithubReleaseClient({http.Client? client})
      : _client = client ?? http.Client();
  final http.Client _client;
  static const _endpoint =
      'https://gitee.com/litttlefisher/private-domain-drive-client/releases/latest/download/private-domain-drive-update.json';

  Future<GithubRelease> latest() async {
    debugPrint('[更新检查] 请求 Gitee 更新清单');
    try {
      final response = await _client.get(Uri.parse(_endpoint));
      debugPrint('[更新检查] 更新清单响应状态：${response.statusCode}');
      if (response.statusCode != 200) {
        debugPrint(
          '[更新检查] 错误响应：${response.body.length > 1000 ? response.body.substring(0, 1000) : response.body}',
        );
        throw StateError('无法获取最新版本（${response.statusCode}）');
      }
      final release = GithubRelease.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
      debugPrint('[更新检查] 最新版本：${release.version}，资产数：${release.assets.length}');
      return release;
    } catch (error, stackTrace) {
      debugPrint('[更新检查] Gitee 请求或解析失败：$error');
      debugPrintStack(stackTrace: stackTrace, label: '[更新检查] 异常堆栈');
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}
