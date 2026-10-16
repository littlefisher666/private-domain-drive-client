import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_domain_drive_client/app/app.dart';
import 'package:private_domain_drive_client/app/bootstrap/app_bootstrap.dart';
import 'package:private_domain_drive_client/core/version/app_version.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/saved_credentials_store.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/auth/presentation/login_page.dart';
import 'package:private_domain_drive_client/features/auth/presentation/splash_page.dart';
import 'package:private_domain_drive_client/features/gallery/application/gallery_controller.dart';
import 'package:private_domain_drive_client/features/settings/application/update_service.dart';
import 'package:private_domain_drive_client/features/settings/infrastructure/github_release_client.dart';
import 'package:private_domain_drive_client/features/settings/presentation/forced_upgrade_page.dart';
import 'package:private_domain_drive_client/shared/state/app_services.dart';

void main() {
  setUpAll(() {
    // 应用外壳构建时经 AppBootstrap.galleryController 注入相册控制器；
    // 这里为整组测试提供一次性的最小实例（门禁路径不读取相册状态）。
    final bootstrapController = AppServices(
      sessionRepository: MemorySessionRepository(),
      savedCredentialsStore:
          SavedCredentialsStore(storage: InMemoryCredentialsStorage()),
    );
    AppBootstrap.galleryController = GalleryController(
      services: bootstrapController,
      ossClient: bootstrapController.ossClient,
    );
  });

  testWidgets('门禁激活时以强制升级页整体替换界面', (tester) async {
    final harness =
        _GateHarness(currentVersion: '1.0.0', minSupportedVersion: '2.0.0');
    final controller = await _pumpApp(tester, harness);
    expect(find.byType(SplashPage), findsOneWidget);

    await controller.settingsController.checkForcedUpgradeGate();
    await tester.pump();

    expect(controller.settingsController.forcedUpgradeActive, isTrue);
    expect(find.byType(ForcedUpgradePage), findsOneWidget);
    // 整棵导航树被替换：启动页、登录页等常规界面不再展示。
    expect(find.byType(SplashPage), findsNothing);
    expect(find.byType(LoginPage), findsNothing);
    expect(find.text('当前版本'), findsOneWidget);
    expect(find.text('1.0.0'), findsOneWidget);
    expect(find.text('最低支持版本'), findsOneWidget);
    expect(find.text('2.0.0'), findsOneWidget);
    expect(find.text('立即升级'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('退出应用'), findsOneWidget);

    await _settleStartupTimers(tester);
  });

  testWidgets('重试后不再强制时解除拦截并恢复原界面', (tester) async {
    final harness =
        _GateHarness(currentVersion: '1.0.0', minSupportedVersion: '2.0.0');
    final controller = await _pumpApp(tester, harness);
    await controller.settingsController.checkForcedUpgradeGate();
    await tester.pump();
    expect(find.byType(ForcedUpgradePage), findsOneWidget);

    harness.minSupportedVersion = '0.9.0';
    await tester.tap(find.text('重试'));
    // 解除拦截后启动页重新挂载并完成启动分流；其加载指示器会让
    // pumpAndSettle 持续走帧直到分流完成。
    await tester.pumpAndSettle();

    expect(controller.settingsController.forcedUpgradeActive, isFalse);
    expect(find.byType(ForcedUpgradePage), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('Android 返回键被拦截且不落入退出应用兜底', (tester) async {
    final calls = _recordPlatformCalls(tester);
    final harness =
        _GateHarness(currentVersion: '1.0.0', minSupportedVersion: '2.0.0');
    final controller = await _pumpApp(tester, harness);
    // 模拟 Android 前台生命周期：框架仅在前台向系统同步返回处理状态。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await controller.settingsController.checkForcedUpgradeGate();
    await tester.pump();
    await tester.pump();
    expect(find.byType(ForcedUpgradePage), findsOneWidget);

    // 门禁页声明由框架处理返回（预测性返回交给框架而非系统直接关应用）。
    expect(
      calls.any((call) =>
          call.method == 'SystemNavigator.setFrameworkHandlesBack' &&
          call.arguments == true),
      isTrue,
    );

    calls.clear();
    final handled = await tester.binding.handlePopRoute();
    await tester.pump();

    // 返回事件被拦截页吞掉，未落入 SystemNavigator.pop 兜底。
    expect(handled, isTrue);
    expect(calls.any((call) => call.method == 'SystemNavigator.pop'), isFalse);
    expect(find.byType(ForcedUpgradePage), findsOneWidget);

    await _settleStartupTimers(tester);
  });

  testWidgets('Android 立即升级失败时展示失败信息与重试入口', (tester) async {
    // 清单资产缺少 digest 时无法应用内安装，点击「立即升级」立即命中失败
    // 兜底；测试环境无法驱动真实文件与网络 I/O，以该路径覆盖失败界面。
    final harness = _GateHarness(
      currentVersion: '1.0.0',
      minSupportedVersion: '2.0.0',
      androidDigest: null,
    );
    final controller = await _pumpApp(tester, harness);
    await controller.settingsController.checkForcedUpgradeGate();
    await tester.pump();
    expect(find.byType(ForcedUpgradePage), findsOneWidget);

    await tester.tap(find.text('立即升级'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('升级失败'), findsOneWidget);
    expect(find.textContaining('当前更新包不支持应用内安装'), findsOneWidget);
    expect(find.text('手动下载'), findsOneWidget);
    // 失败后可再次点击立即升级重试。
    final retryButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '立即升级'),
    );
    expect(retryButton.onPressed, isNotNull);

    await _settleStartupTimers(tester);
  });

  testWidgets('退出应用按钮经系统通道退出', (tester) async {
    final calls = _recordPlatformCalls(tester);
    final harness =
        _GateHarness(currentVersion: '1.0.0', minSupportedVersion: '2.0.0');
    final controller = await _pumpApp(tester, harness);
    await controller.settingsController.checkForcedUpgradeGate();
    await tester.pump();
    expect(find.byType(ForcedUpgradePage), findsOneWidget);

    calls.clear();
    await tester.tap(find.text('退出应用'));
    await tester.pump();

    expect(calls.any((call) => call.method == 'SystemNavigator.pop'), isTrue);

    await _settleStartupTimers(tester);
  });
}

Future<AppServices> _pumpApp(WidgetTester tester, _GateHarness harness) async {
  final controller = AppServices(
    sessionRepository: MemorySessionRepository(),
    savedCredentialsStore:
        SavedCredentialsStore(storage: InMemoryCredentialsStorage()),
    updateService: harness.service,
    disableStartupUpdateCheck: false,
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(PrivateDomainDriveApp(services: controller));
  return controller;
}

/// SplashPage 的 350ms 路由计时器等内容计时器需要在测试结束前触发，
/// 否则 flutter_test 会以“仍有未完成 Timer”失败。
Future<void> _settleStartupTimers(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// 记录 SystemChannels.platform 上的方法调用，供返回键与退出应用断言。
List<MethodCall> _recordPlatformCalls(WidgetTester tester) {
  final calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      calls.add(call);
      return null;
    },
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

/// 门禁检查用假服务：以可变状态模拟门槛调整与请求计数。
class _GateHarness {
  _GateHarness({
    required this.currentVersion,
    required this.minSupportedVersion,
    this.androidDigest = 'sha256:abc',
  });

  static const _releasesPath =
      '/repos/littlefisher666/private-domain-drive-client/releases';

  final String currentVersion;
  String minSupportedVersion;

  /// 清单中 Android 资产的 digest；为 null 时模拟缺 digest 的清单。
  final String? androidDigest;
  int requests = 0;

  late final UpdateService service = UpdateService(
    versionReader: _FixedAppVersionReader(currentVersion),
    releaseClient: GithubReleaseClient(
      client: MockClient((request) async {
        requests += 1;
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
              'digest': androidDigest,
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
