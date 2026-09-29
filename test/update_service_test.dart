import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_domain_drive_client/core/version/app_version.dart';
import 'package:private_domain_drive_client/features/settings/application/update_service.dart';
import 'package:private_domain_drive_client/features/settings/infrastructure/github_release_client.dart';

class _FixedVersionReader implements AppVersionReader {
  _FixedVersionReader(this.version);
  final String version;

  @override
  Future<AppVersion> read() async => AppVersion(name: version, buildNumber: '1');
}

const _releasesPath = '/repos/littlefisher666/private-domain-drive-client/releases';

GithubReleaseClient _clientWith({
  required List<Map<String, dynamic>> releases,
  Map<String, dynamic>? manifest,
}) {
  return GithubReleaseClient(
    client: MockClient((request) async {
      if (request.url.path == _releasesPath) {
        return http.Response.bytes(
          utf8.encode(jsonEncode(releases)),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (manifest == null) return http.Response('not found', 404);
      return http.Response.bytes(
        utf8.encode(jsonEncode(manifest)),
        200,
        headers: {'content-type': 'application/octet-stream'},
      );
    }),
  );
}

UpdateService _serviceWith({
  required String currentVersion,
  required List<Map<String, dynamic>> releases,
  Map<String, dynamic>? manifest,
}) {
  return UpdateService(
    versionReader: _FixedVersionReader(currentVersion),
    releaseClient: _clientWith(releases: releases, manifest: manifest),
  );
}

Map<String, dynamic> _apiRelease({
  required String tagName,
}) {
  return {
    'tag_name': tagName,
    'assets': [
      {
        'name': 'private-domain-drive-update.json',
        'browser_download_url':
            'https://example.com/download/$tagName/private-domain-drive-update.json',
      },
    ],
  };
}

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('解析静态更新清单', () {
    final release = GithubRelease.fromJson({
      'version': '1.0.4',
      'notes': '',
      'assets': {
        'android': {
          'name': 'private-domain-drive-android-v1.0.4.apk',
          'url': 'https://example.com/android.apk',
          'digest': 'sha256:abc',
        },
        'macos': {
          'name': 'private-domain-drive-macos-v1.0.4.dmg',
          'url': 'https://example.com/macos.dmg',
          'digest': 'sha256:def',
        },
      },
    });

    expect(release.version, '1.0.4');
    expect(release.assets, hasLength(2));
    expect(release.assets.first.digest, 'sha256:abc');
  });

  test('解析单平台静态更新清单', () {
    final release = GithubRelease.fromJson({
      'version': '1.2.4',
      'notes': '修复',
      'assets': {
        'android': {
          'name': 'private-domain-drive-android-v1.2.4.apk',
          'url': 'https://example.com/android.apk',
          'digest': 'sha256:abc',
        },
      },
    });

    expect(release.version, '1.2.4');
    expect(release.assets, hasLength(1));
  });

  test('比较语义化版本', () {
    expect(UpdateService.compareVersions('1.0.4', '1.0.3'), greaterThan(0));
    expect(UpdateService.compareVersions('v1.0.3', '1.0.3'), 0);
    expect(UpdateService.compareVersions('1.0.2', '1.0.3'), lessThan(0));
  });

  test('Android 端发现本平台新版本', () async {
    final service = _serviceWith(
      currentVersion: '1.2.3',
      releases: [_apiRelease(tagName: 'android/v1.2.4')],
      manifest: {
        'version': '1.2.4',
        'notes': '修复 Android 问题',
        'assets': {
          'android': {
            'name': 'private-domain-drive-android-v1.2.4.apk',
            'url': 'https://example.com/android.apk',
            'digest': 'sha256:abc',
          },
        },
      },
    );

    final result = await service.checkLatest();
    expect(result.latestVersion, '1.2.4');
    expect(result.hasUpdate, isTrue);
    expect(result.availableUpdate, isNotNull);
    expect(result.availableUpdate!.asset.digest, 'sha256:abc');
  });

  test('另一端单独发版时本端不提示更新', () async {
    final service = _serviceWith(
      currentVersion: '1.2.3',
      releases: [
        _apiRelease(tagName: 'android/v1.2.3'),
        _apiRelease(tagName: 'macos/v1.3.0'),
      ],
      manifest: {
        'version': '1.2.3',
        'notes': '',
        'assets': {
          'android': {
            'name': 'private-domain-drive-android-v1.2.3.apk',
            'url': 'https://example.com/android.apk',
            'digest': 'sha256:abc',
          },
        },
      },
    );

    final result = await service.checkLatest();
    expect(result.latestVersion, '1.2.3');
    expect(result.hasUpdate, isFalse);
    expect(result.availableUpdate, isNull);
  });

  test('无平台匹配的 Release 时静默返回且不报错', () async {
    final service = _serviceWith(
      currentVersion: '1.2.3',
      releases: [_apiRelease(tagName: 'v1.3.0')],
    );

    final result = await service.checkLatest();
    expect(result.latestVersion, '');
    expect(result.hasUpdate, isFalse);
    expect(result.availableUpdate, isNull);
  });

  test('清单缺少本平台资产时不视为可更新', () async {
    final service = _serviceWith(
      currentVersion: '1.2.3',
      releases: [_apiRelease(tagName: 'android/v2.0.0')],
      manifest: {
        'version': '2.0.0',
        'notes': '',
        'assets': {
          'macos': {
            'name': 'private-domain-drive-macos-v2.0.0.dmg',
            'url': 'https://example.com/macos.dmg',
            'digest': 'sha256:def',
          },
        },
      },
    );

    final result = await service.checkLatest();
    expect(result.latestVersion, '2.0.0');
    expect(result.hasUpdate, isTrue);
    expect(result.availableUpdate, isNull);
  });

  test('macOS 端按平台前缀匹配并忽略其他平台的新版本', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final service = _serviceWith(
      currentVersion: '1.2.3',
      releases: [
        _apiRelease(tagName: 'android/v2.0.0'),
        _apiRelease(tagName: 'macos/v1.2.5'),
      ],
      manifest: {
        'version': '1.2.5',
        'notes': '修复 macOS 问题',
        'assets': {
          'macos': {
            'name': 'private-domain-drive-macos-v1.2.5.dmg',
            'url': 'https://example.com/macos.dmg',
            'digest': 'sha256:def',
          },
        },
      },
    );

    final result = await service.checkLatest();
    expect(result.latestVersion, '1.2.5');
    expect(result.hasUpdate, isTrue);
    expect(result.availableUpdate, isNotNull);
    expect(result.availableUpdate!.asset.name,
        'private-domain-drive-macos-v1.2.5.dmg');
  });

  test('平台发布缺少更新清单资产时静默返回', () async {
    final service = _serviceWith(
      currentVersion: '1.2.3',
      releases: [
        {
          'tag_name': 'android/v1.2.4',
          'assets': [
            {
              'name': 'private-domain-drive-android-v1.2.4.apk',
              'browser_download_url': 'https://example.com/android.apk',
            },
          ],
        },
      ],
    );

    final result = await service.checkLatest();
    expect(result.latestVersion, '');
    expect(result.hasUpdate, isFalse);
    expect(result.availableUpdate, isNull);
  });
}
