import 'dart:convert';

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

  factory GithubRelease.fromJson(Map<String, dynamic> json) => GithubRelease(
        version: (json['tag_name'] as String).replaceFirst(RegExp(r'^v'), ''),
        notes: (json['body'] as String?) ?? '',
        assets: (json['assets'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map((asset) => ReleaseAsset(
                  name: asset['name'] as String,
                  url: asset['browser_download_url'] as String,
                  digest: asset['digest'] as String?,
                ))
            .toList(),
      );
}

class GithubReleaseClient {
  GithubReleaseClient({http.Client? client})
      : _client = client ?? http.Client();
  final http.Client _client;
  static const _endpoint =
      'https://api.github.com/repos/littlefisher666/private-domain-drive-client/releases/latest';

  Future<GithubRelease> latest() async {
    final response = await _client.get(Uri.parse(_endpoint), headers: const {
      'Accept': 'application/vnd.github+json',
    });
    if (response.statusCode != 200)
      throw StateError('无法获取最新版本（${response.statusCode}）');
    return GithubRelease.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }
}
