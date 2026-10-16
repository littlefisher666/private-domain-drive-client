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
  Future<AppVersion> read() async =>
      AppVersion(name: version, buildNumber: '1');
}

const _releasesPath =
    '/repos/littlefisher666/private-domain-drive-client/releases';
const _ossHost = 'private-domain-drive.oss-cn-hangzhou.aliyuncs.com';
const _ossFeedPath = '/releases/android/update.json';

GithubReleaseClient _clientWith({
  required List<Map<String, dynamic>> releases,
  Map<String, dynamic>? manifest,
  Map<String, dynamic>? ossManifest,
  int ossStatus = 404,
  bool ossThrows = false,
  List<Uri>? requestLog,
}) {
  return GithubReleaseClient(
    client: MockClient((request) async {
      requestLog?.add(request.url);
      if (request.url.host == _ossHost) {
        if (ossThrows) throw http.ClientException('连接失败');
        if (ossManifest == null) return http.Response('not found', ossStatus);
        return http.Response.bytes(
          utf8.encode(jsonEncode(ossManifest)),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
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
  Map<String, dynamic>? ossManifest,
  int ossStatus = 404,
  bool ossThrows = false,
  List<Uri>? requestLog,
}) {
  return UpdateService(
    versionReader: _FixedVersionReader(currentVersion),
    releaseClient: _clientWith(
      releases: releases,
      manifest: manifest,
      ossManifest: ossManifest,
      ossStatus: ossStatus,
      ossThrows: ossThrows,
      requestLog: requestLog,
    ),
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

  test('列表顺序不代表最新时取版本号最高的平台发布', () async {
    // 复现 GitHub 实测乱序：旧共享序列与低版本平台条目排在前面。
    final service = _serviceWith(
      currentVersion: '0.0.9',
      releases: [
        _apiRelease(tagName: 'v0.0.9'),
        _apiRelease(tagName: 'macos/v0.0.9'),
        _apiRelease(tagName: 'android/v0.0.9'),
        _apiRelease(tagName: 'android/v0.0.10'),
      ],
      manifest: {
        'version': '0.0.10',
        'notes': '修复',
        'assets': {
          'android': {
            'name': 'private-domain-drive-android-v0.0.10.apk',
            'url': 'https://example.com/android.apk',
            'digest': 'sha256:abc',
          },
        },
      },
    );

    final result = await service.checkLatest();
    expect(result.latestVersion, '0.0.10');
    expect(result.hasUpdate, isTrue);
    expect(result.availableUpdate, isNotNull);
    expect(result.availableUpdate!.asset.name,
        'private-domain-drive-android-v0.0.10.apk');
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

  test('解析最低支持版本字段并去除 v 前缀', () {
    final release = GithubRelease.fromJson({
      'version': '1.2.4',
      'notes': '',
      'minSupportedVersion': 'v1.2.0',
      'assets': {
        'android': {
          'name': 'private-domain-drive-android-v1.2.4.apk',
          'url': 'https://example.com/android.apk',
          'digest': 'sha256:abc',
        },
      },
    });
    expect(release.minSupportedVersion, '1.2.0');
  });

  test('最低支持版本缺省、空串或非字符串时按不限制解析', () {
    Map<String, dynamic> manifest(Object? value) => {
          'version': '1.2.4',
          'notes': '',
          if (value != null) 'minSupportedVersion': value,
          'assets': {
            'android': {
              'name': 'private-domain-drive-android-v1.2.4.apk',
              'url': 'https://example.com/android.apk',
              'digest': 'sha256:abc',
            },
          },
        };

    expect(GithubRelease.fromJson(manifest(null)).minSupportedVersion, isNull);
    expect(GithubRelease.fromJson(manifest('')).minSupportedVersion, isNull);
    expect(GithubRelease.fromJson(manifest('  ')).minSupportedVersion, isNull);
    expect(GithubRelease.fromJson(manifest(1.2)).minSupportedVersion, isNull);
  });

  group('强制升级判定', () {
    UpdateCheckResult result({required String current, String? minimum}) =>
        UpdateCheckResult(
          currentVersion: current,
          latestVersion: '9.9.9',
          minSupportedVersion: minimum,
        );

    test('当前版本低于最低支持版本时判定为强制', () {
      expect(
        result(current: '1.1.4', minimum: '1.2.0').requiresForcedUpgrade,
        isTrue,
      );
    });

    test('当前版本等于或高于最低支持版本时不判定', () {
      expect(
        result(current: '1.2.0', minimum: '1.2.0').requiresForcedUpgrade,
        isFalse,
      );
      expect(
        result(current: '1.2.1', minimum: '1.2.0').requiresForcedUpgrade,
        isFalse,
      );
    });

    test('比较忽略 +build 构建号', () {
      expect(
        result(current: '1.1.4+9', minimum: '1.2.0').requiresForcedUpgrade,
        isTrue,
      );
      expect(
        result(current: '1.2.0+9', minimum: '1.2.0').requiresForcedUpgrade,
        isFalse,
      );
    });

    test('缺省、空值或无法解析时不判定', () {
      expect(result(current: '1.1.4').requiresForcedUpgrade, isFalse);
      expect(
        result(current: '1.1.4', minimum: '').requiresForcedUpgrade,
        isFalse,
      );
      expect(
        result(current: '1.1.4', minimum: 'abc').requiresForcedUpgrade,
        isFalse,
      );
    });
  });

  test('checkLatest 传递最低支持版本并判定强制', () async {
    final service = _serviceWith(
      currentVersion: '1.1.4',
      releases: [_apiRelease(tagName: 'android/v1.2.0')],
      manifest: {
        'version': '1.2.0',
        'notes': '',
        'minSupportedVersion': '1.2.0',
        'assets': {
          'android': {
            'name': 'private-domain-drive-android-v1.2.0.apk',
            'url': 'https://example.com/android.apk',
            'digest': 'sha256:abc',
          },
        },
      },
    );

    final result = await service.checkLatest();
    expect(result.minSupportedVersion, '1.2.0');
    expect(result.requiresForcedUpgrade, isTrue);
    expect(result.availableUpdate, isNotNull);
  });

  test('清单缺少本平台资产时仍判定强制且无升级资产', () async {
    final service = _serviceWith(
      currentVersion: '1.1.4',
      releases: [_apiRelease(tagName: 'android/v1.2.0')],
      manifest: {
        'version': '1.2.0',
        'notes': '',
        'minSupportedVersion': '1.2.0',
        'assets': {
          'macos': {
            'name': 'private-domain-drive-macos-v1.2.0.dmg',
            'url': 'https://example.com/macos.dmg',
            'digest': 'sha256:def',
          },
        },
      },
    );

    final result = await service.checkLatest();
    expect(result.minSupportedVersion, '1.2.0');
    expect(result.requiresForcedUpgrade, isTrue);
    expect(result.availableUpdate, isNull);
  });

  test('清单版本不高于当前版本时门槛仍参与判定（沿用清单场景）', () async {
    final service = _serviceWith(
      currentVersion: '1.3.0',
      releases: [_apiRelease(tagName: 'android/v1.2.0')],
      manifest: {
        'version': '1.2.0',
        'notes': '',
        'minSupportedVersion': '1.2.0',
        'assets': {
          'android': {
            'name': 'private-domain-drive-android-v1.2.0.apk',
            'url': 'https://example.com/android.apk',
            'digest': 'sha256:abc',
          },
        },
      },
    );

    final result = await service.checkLatest();
    expect(result.minSupportedVersion, '1.2.0');
    expect(result.requiresForcedUpgrade, isFalse);
  });

  test('macOS 端读取清单门槛用于强制判定', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final service = _serviceWith(
      currentVersion: '1.1.4',
      releases: [_apiRelease(tagName: 'macos/v1.2.0')],
      manifest: {
        'version': '1.2.0',
        'notes': '',
        'minSupportedVersion': 'v1.2.0',
        'assets': {
          'macos': {
            'name': 'private-domain-drive-macos-v1.2.0.dmg',
            'url': 'https://example.com/macos.dmg',
            'digest': 'sha256:def',
          },
        },
      },
    );

    final result = await service.checkLatest();
    expect(result.minSupportedVersion, '1.2.0');
    expect(result.requiresForcedUpgrade, isTrue);
    expect(result.availableUpdate, isNotNull);
  });

  test('旧清单缺少最低支持版本字段时不判定强制', () async {
    final service = _serviceWith(
      currentVersion: '1.2.3',
      releases: [_apiRelease(tagName: 'android/v1.2.4')],
      manifest: {
        'version': '1.2.4',
        'notes': '',
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
    expect(result.minSupportedVersion, isNull);
    expect(result.requiresForcedUpgrade, isFalse);
    expect(result.hasUpdate, isTrue);
  });

  test('OSS 清单命中时优先采用且不再请求 GitHub', () async {
    final requestLog = <Uri>[];
    final service = _serviceWith(
      currentVersion: '1.2.3',
      releases: const [],
      ossManifest: {
        'version': '1.3.0',
        'notes': 'OSS 优先',
        'assets': {
          'android': {
            'name': 'private-domain-drive-android-v1.3.0.apk',
            'url': 'https://$_ossHost/releases/android/'
                'private-domain-drive-android-v1.3.0.apk.bin',
            'digest': 'sha256:abc',
          },
        },
      },
      requestLog: requestLog,
    );

    final result = await service.checkLatest();
    expect(result.latestVersion, '1.3.0');
    expect(result.hasUpdate, isTrue);
    expect(result.availableUpdate, isNotNull);
    expect(result.availableUpdate!.asset.digest, 'sha256:abc');
    // 仅一次 OSS 清单请求，未触达 GitHub Releases 列表。
    expect(requestLog, hasLength(1));
    expect(requestLog.single.host, _ossHost);
    expect(requestLog.single.path, _ossFeedPath);
  });

  test('OSS 清单非 200 时回退 GitHub 链路', () async {
    final service = _serviceWith(
      currentVersion: '1.2.3',
      releases: [_apiRelease(tagName: 'android/v1.2.4')],
      manifest: {
        'version': '1.2.4',
        'notes': '',
        'assets': {
          'android': {
            'name': 'private-domain-drive-android-v1.2.4.apk',
            'url': 'https://example.com/android.apk',
            'digest': 'sha256:abc',
          },
        },
      },
      ossStatus: 500,
    );

    final result = await service.checkLatest();
    expect(result.latestVersion, '1.2.4');
    expect(result.availableUpdate, isNotNull);
  });

  test('OSS 清单请求异常时回退 GitHub 链路', () async {
    final service = _serviceWith(
      currentVersion: '1.2.3',
      releases: [_apiRelease(tagName: 'android/v1.2.4')],
      manifest: {
        'version': '1.2.4',
        'notes': '',
        'assets': {
          'android': {
            'name': 'private-domain-drive-android-v1.2.4.apk',
            'url': 'https://example.com/android.apk',
            'digest': 'sha256:abc',
          },
        },
      },
      ossThrows: true,
    );

    final result = await service.checkLatest();
    expect(result.latestVersion, '1.2.4');
    expect(result.availableUpdate, isNotNull);
  });

  test('OSS 清单解析失败时回退 GitHub 链路', () async {
    final service = _serviceWith(
      currentVersion: '1.2.3',
      releases: [_apiRelease(tagName: 'android/v1.2.4')],
      manifest: {
        'version': '1.2.4',
        'notes': '',
        'assets': {
          'android': {
            'name': 'private-domain-drive-android-v1.2.4.apk',
            'url': 'https://example.com/android.apk',
            'digest': 'sha256:abc',
          },
        },
      },
      ossManifest: const {'version': '1.3.0', 'assets': 'oops'},
    );

    final result = await service.checkLatest();
    expect(result.latestVersion, '1.2.4');
    expect(result.availableUpdate, isNotNull);
  });
}
