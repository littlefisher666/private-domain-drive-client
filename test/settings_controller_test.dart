import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_domain_drive_client/core/version/app_version.dart';
import 'package:private_domain_drive_client/features/settings/application/settings_controller.dart';
import 'package:private_domain_drive_client/features/settings/application/update_service.dart';
import 'package:private_domain_drive_client/features/settings/infrastructure/github_release_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SettingsController', () {
    test('启动后恢复显示模式，并保存新的选择', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'theme_mode': 'dark',
      });
      final controller = SettingsController();
      addTearDown(controller.dispose);
      controller.restorePreferences(await SharedPreferences.getInstance());

      expect(controller.themeMode, ThemeMode.dark);

      await controller.setThemeMode(ThemeMode.light);
      expect(
        (await SharedPreferences.getInstance()).getString('theme_mode'),
        'light',
      );
    });
  });

  group('强制升级门禁', () {
    SettingsController controllerWithGate(
      _GateHarness harness, {
      bool disableStartupUpdateCheck = false,
    }) {
      final controller = SettingsController(
        updateService: harness.service,
        disableStartupUpdateCheck: disableStartupUpdateCheck,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('当前版本低于最低支持版本时门禁生效', () async {
      final harness = _GateHarness(currentVersion: '1.1.4');
      final controller = controllerWithGate(harness);
      expect(controller.forcedUpgradeActive, isFalse);

      await controller.checkForcedUpgradeGate();

      expect(controller.forcedUpgradeActive, isTrue);
      expect(controller.forcedUpgradeResult!.minSupportedVersion, '1.2.0');
      expect(controller.forcedUpgradeResult!.availableUpdate, isNotNull);
    });

    test('不低于最低支持版本时放行', () async {
      final harness = _GateHarness(currentVersion: '1.2.0');
      final controller = controllerWithGate(harness);

      await controller.checkForcedUpgradeGate();

      expect(controller.forcedUpgradeActive, isFalse);
      expect(controller.forcedUpgradeResult, isNull);
    });

    test('检查失败静默放行且不缓存结论，下次检查重新判定', () async {
      final harness = _GateHarness(currentVersion: '1.1.4')..offline = true;
      final controller = controllerWithGate(harness);

      await controller.checkForcedUpgradeGate();
      expect(controller.forcedUpgradeActive, isFalse);

      harness.offline = false;
      await controller.checkForcedUpgradeGate();
      expect(controller.forcedUpgradeActive, isTrue);
    });

    test('拦截期间重试失败保持拦截，门槛解除后重试放行', () async {
      final harness = _GateHarness(currentVersion: '1.1.4');
      final controller = controllerWithGate(harness);
      await controller.checkForcedUpgradeGate();
      expect(controller.forcedUpgradeActive, isTrue);

      harness.offline = true;
      await controller.checkForcedUpgradeGate();
      expect(controller.forcedUpgradeActive, isTrue);

      harness.offline = false;
      harness.minSupportedVersion = '1.0.0';
      await controller.checkForcedUpgradeGate();
      expect(controller.forcedUpgradeActive, isFalse);
    });

    test('调试开关跳过启动检查也不拦截', () async {
      final harness = _GateHarness(currentVersion: '1.1.4');
      final controller =
          controllerWithGate(harness, disableStartupUpdateCheck: true);

      await controller.checkForcedUpgradeGate();

      expect(harness.requests, 0);
      expect(controller.forcedUpgradeActive, isFalse);
    });
  });
}

/// 门禁检查用假服务：以可变状态模拟离线、门槛调整与请求计数。
class _GateHarness {
  _GateHarness({required this.currentVersion});

  static const _releasesPath =
      '/repos/littlefisher666/private-domain-drive-client/releases';

  final String currentVersion;
  String minSupportedVersion = '1.2.0';
  bool offline = false;
  int requests = 0;

  late final UpdateService service = UpdateService(
    versionReader: _FixedAppVersionReader(currentVersion),
    releaseClient: GithubReleaseClient(
      client: MockClient((request) async {
        requests += 1;
        if (offline) {
          throw http.ClientException('mock offline');
        }
        if (request.url.path == _releasesPath) {
          return _jsonResponse(<Map<String, dynamic>>[
            {
              'tag_name': 'android/v$minSupportedVersion',
              'assets': [
                {
                  'name': 'private-domain-drive-update.json',
                  'browser_download_url':
                      'https://example.com/private-domain-drive-update.json',
                },
              ],
            },
          ]);
        }
        return _jsonResponse(<String, dynamic>{
          'version': minSupportedVersion,
          'notes': '',
          'minSupportedVersion': minSupportedVersion,
          'assets': {
            'android': {
              'name': 'private-domain-drive-android-v$minSupportedVersion.apk',
              'url': 'https://example.com/android.apk',
              'digest': 'sha256:abc',
            },
          },
        });
      }),
    ),
  );
}

class _FixedAppVersionReader implements AppVersionReader {
  _FixedAppVersionReader(this.version);

  final String version;

  @override
  Future<AppVersion> read() async => AppVersion(name: version, buildNumber: '1');
}

http.Response _jsonResponse(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json'},
    );
