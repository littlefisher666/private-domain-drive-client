import 'package:auto_updater/auto_updater.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/settings/infrastructure/macos_sparkle_updater.dart';

class _FakeSparkleApi implements SparkleUpdaterApi {
  _FakeSparkleApi();

  UpdaterListener? listener;
  String? feedUrl;
  final List<bool?> checkCalls = <bool?>[];

  @override
  void addListener(UpdaterListener listener) => this.listener = listener;

  @override
  Future<void> setFeedURL(String feedUrl) async => this.feedUrl = feedUrl;

  @override
  Future<void> checkForUpdates({bool? inBackground}) async =>
      checkCalls.add(inBackground);
}

AppcastItem _item(String version) => AppcastItem(
      versionString: version,
      displayVersionString: version,
      fileURL: 'https://example.com/app.zip',
      contentLength: 1,
      infoURL: '',
      title: '',
      dateString: '',
      releaseNotesURL: '',
      itemDescription: '',
      itemDescriptionFormat: '',
      fullReleaseNotesURL: '',
      minimumSystemVersion: '',
      minimumOperatingSystemVersionIsOK: true,
      maximumSystemVersion: '',
      maximumOperatingSystemVersionIsOK: true,
      channel: '',
    );

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('平台分流：macOS 走 Sparkle，其余平台走清单检查', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(usesSparkleUpdate(defaultTargetPlatform), isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(usesSparkleUpdate(defaultTargetPlatform), isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(usesSparkleUpdate(defaultTargetPlatform), isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(usesSparkleUpdate(defaultTargetPlatform), isFalse);
  });

  test('初始化设置 feed 地址并注册事件监听', () async {
    final api = _FakeSparkleApi();
    final updater = MacosSparkleUpdater(api: api);

    await updater.initialize();

    expect(api.feedUrl, MacosSparkleUpdater.defaultFeedUrl);
    expect(api.listener, same(updater));
  });

  test('手动检查进入检查中状态并以前台方式发起', () async {
    final api = _FakeSparkleApi();
    final updater = MacosSparkleUpdater(api: api);

    await updater.checkManually();

    expect(updater.status, SparkleUpdateStatus.checking);
    expect(api.checkCalls, [false]);
  });

  test('启动静默检查以后台方式发起', () async {
    final api = _FakeSparkleApi();
    final updater = MacosSparkleUpdater(api: api);

    await updater.startupCheck();

    expect(api.checkCalls, [true]);
  });

  test('检查失败进入失败状态并通知监听者', () async {
    final api = _FakeSparkleApi();
    final updater = MacosSparkleUpdater(api: api);
    final statuses = <SparkleUpdateStatus>[];
    updater.statusStream.listen(statuses.add);

    await updater.checkManually();
    updater.onUpdaterError(UpdaterError('网络错误'));
    await pumpEventQueue();

    expect(updater.status, SparkleUpdateStatus.failed);
    expect(statuses, contains(SparkleUpdateStatus.failed));
  });

  test('已是最新版本进入 upToDate 状态', () async {
    final api = _FakeSparkleApi();
    final updater = MacosSparkleUpdater(api: api);

    await updater.checkManually();
    updater.onUpdaterUpdateNotAvailable(null);

    expect(updater.status, SparkleUpdateStatus.upToDate);
  });

  test('发现新版本记录版本号并回到空闲状态交由原生弹窗接管', () async {
    final api = _FakeSparkleApi();
    final updater = MacosSparkleUpdater(api: api);

    await updater.checkManually();
    updater.onUpdaterUpdateAvailable(_item('1.2.4'));

    expect(updater.status, SparkleUpdateStatus.idle);
    expect(updater.latestVersion, '1.2.4');
  });

  test('重复状态不重复广播', () async {
    final api = _FakeSparkleApi();
    final updater = MacosSparkleUpdater(api: api);
    final statuses = <SparkleUpdateStatus>[];
    updater.statusStream.listen(statuses.add);

    updater.onUpdaterError(UpdaterError('网络错误'));
    updater.onUpdaterError(UpdaterError('网络错误'));
    await pumpEventQueue();

    expect(statuses, [SparkleUpdateStatus.failed]);
  });
}
