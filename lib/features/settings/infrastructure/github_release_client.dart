import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/version/app_version.dart';

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

  static const _releasesEndpoint =
      'https://api.github.com/repos/littlefisher666/private-domain-drive-client/releases?per_page=30';
  static const _manifestAssetName = 'private-domain-drive-update.json';
  static const _headers = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'private-domain-drive-client',
  };

  /// 查询当前平台的最新发布：从 Releases 列表中按 tag 前缀
  /// （`android/` 或 `macos/`）匹配，并选取其中**版本号最高**的一个，
  /// 下载其更新清单。列表顺序不保证最新在前（GitHub 实测会穿插旧共享
  /// 序列与各平台条目），因此不得依赖接口排序取第一个。
  /// 没有平台匹配的发布或清单资产时返回 null，由调用方按“已是最新版本”处理。
  Future<GithubRelease?> latestForPlatform({required String tagPrefix}) async {
    debugPrint('[更新检查] 查询平台发布列表（tag 前缀：$tagPrefix）');
    try {
      final releases = await _fetchReleases();
      final versionPattern = RegExp(r'^\d+\.\d+\.\d+$');
      final candidates = releases
          .map((release) => release['tag_name'] as String? ?? '')
          .where((tag) => tag.startsWith(tagPrefix))
          .map((tag) => (
                tag: tag,
                version: tag
                    .substring(tagPrefix.length)
                    .replaceFirst(RegExp(r'^v'), ''),
              ))
          .where((candidate) => versionPattern.hasMatch(candidate.version))
          .toList()
        ..sort((a, b) => compareAppVersions(b.version, a.version));
      final best = candidates.firstOrNull;
      if (best == null) {
        debugPrint('[更新检查] 未找到前缀为 $tagPrefix 的发布');
        return null;
      }
      debugPrint('[更新检查] 平台最新发布：${best.tag}（候选 ${candidates.length} 个）');
      final matched = releases
          .firstWhere((release) => release['tag_name'] == best.tag);
      debugPrint('[更新检查] 匹配到平台发布：${matched['tag_name']}');
      final manifestUrl = ((matched['assets'] as List<dynamic>? ?? const [])
              .cast<Map<String, dynamic>>()
              .where((asset) => asset['name'] == _manifestAssetName)
              .map((asset) => asset['browser_download_url'] as String?))
          .firstOrNull;
      if (manifestUrl == null) {
        debugPrint('[更新检查] 平台发布缺少更新清单资产');
        return null;
      }
      debugPrint('[更新检查] 下载更新清单：$manifestUrl');
      final response = await _client.get(
        Uri.parse(manifestUrl),
        headers: _headers,
      );
      debugPrint('[更新检查] 更新清单响应状态：${response.statusCode}');
      if (response.statusCode != 200) {
        debugPrint(
          '[更新检查] 错误响应：${response.body.length > 1000 ? response.body.substring(0, 1000) : response.body}',
        );
        throw StateError('无法获取最新版本（${response.statusCode}）');
      }
      // GitHub 以 application/octet-stream 返回清单且不带 charset，
      // http 包默认按 latin1 解码 body 会导致中文乱码，这里强制按 UTF-8 解码。
      final body = utf8.decode(response.bodyBytes);
      final release = GithubRelease.fromJson(
        jsonDecode(body) as Map<String, dynamic>,
      );
      debugPrint('[更新检查] 平台最新版本：${release.version}，资产数：${release.assets.length}');
      return release;
    } catch (error, stackTrace) {
      debugPrint('[更新检查] GitHub 请求或解析失败：$error');
      debugPrintStack(stackTrace: stackTrace, label: '[更新检查] 异常堆栈');
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<List<Map<String, dynamic>>> _fetchReleases() async {
    final response = await _client.get(
      Uri.parse(_releasesEndpoint),
      headers: _headers,
    );
    debugPrint('[更新检查] 发布列表响应状态：${response.statusCode}');
    if (response.statusCode != 200) {
      debugPrint(
        '[更新检查] 错误响应：${response.body.length > 1000 ? response.body.substring(0, 1000) : response.body}',
      );
      throw StateError('无法获取最新版本（${response.statusCode}）');
    }
    // GitHub API 响应同样不带 charset，强制按 UTF-8 解码。
    final body = utf8.decode(response.bodyBytes);
    return (jsonDecode(body) as List<dynamic>).cast<Map<String, dynamic>>();
  }
}
