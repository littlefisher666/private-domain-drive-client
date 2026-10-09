import 'dart:async';

import 'package:auto_updater/auto_updater.dart';
import 'package:flutter/foundation.dart';

bool usesSparkleUpdate(TargetPlatform platform) =>
    platform == TargetPlatform.macOS;

enum SparkleUpdateStatus { idle, checking, upToDate, failed }

abstract class SparkleUpdaterApi {
  void addListener(UpdaterListener listener);
  Future<void> setFeedURL(String feedUrl);
  Future<void> checkForUpdates({bool? inBackground});
}

class PluginSparkleUpdaterApi implements SparkleUpdaterApi {
  const PluginSparkleUpdaterApi();

  @override
  void addListener(UpdaterListener listener) =>
      AutoUpdater.instance.addListener(listener);

  @override
  Future<void> setFeedURL(String feedUrl) =>
      AutoUpdater.instance.setFeedURL(feedUrl);

  @override
  Future<void> checkForUpdates({bool? inBackground}) =>
      AutoUpdater.instance.checkForUpdates(inBackground: inBackground);
}

/// macOS 端 Sparkle 自更新适配层。
///
/// 更新确认、下载与安装交互由 Sparkle 原生弹窗承担；这里只维护一个轻量状态机，
/// 供设置页展示检查中/失败反馈，失败时提供手动下载兜底入口。
class MacosSparkleUpdater implements UpdaterListener {
  MacosSparkleUpdater({
    this.feedUrl = defaultFeedUrl,
    @visibleForTesting SparkleUpdaterApi api = const PluginSparkleUpdaterApi(),
  }) : _api = api;

  static const String defaultFeedUrl =
      'https://raw.githubusercontent.com/littlefisher666/private-domain-drive-client/appcast/appcast.xml';

  static final MacosSparkleUpdater instance = MacosSparkleUpdater();

  final String feedUrl;
  final SparkleUpdaterApi _api;

  final StreamController<SparkleUpdateStatus> _statusController =
      StreamController<SparkleUpdateStatus>.broadcast();

  bool _initialized = false;
  SparkleUpdateStatus _status = SparkleUpdateStatus.idle;
  String? _latestVersion;

  SparkleUpdateStatus get status => _status;

  /// 检查到的新版本号，仅在收到 update-available 事件后有值。
  String? get latestVersion => _latestVersion;

  Stream<SparkleUpdateStatus> get statusStream => _statusController.stream;

  Future<void> initialize() async {
    if (_initialized) return;
    _api.addListener(this);
    await _api.setFeedURL(feedUrl);
    _initialized = true;
  }

  /// 启动后的静默检查；Sparkle 自动检查失败时不打扰用户。
  Future<void> startupCheck() async {
    await initialize();
    unawaited(_api.checkForUpdates(inBackground: true));
  }

  /// 设置页手动检查；发现更新或已是最新时由 Sparkle 原生弹窗反馈。
  Future<void> checkManually() async {
    await initialize();
    _setStatus(SparkleUpdateStatus.checking);
    await _api.checkForUpdates(inBackground: false);
  }

  @override
  void onUpdaterError(UpdaterError? error) {
    debugPrint('[Sparkle] 更新检查失败：${error?.message}');
    _setStatus(SparkleUpdateStatus.failed);
  }

  @override
  void onUpdaterCheckingForUpdate(Appcast? appcast) {
    // appcast 加载完成，等待后续 available / not-available 事件。
  }

  @override
  void onUpdaterUpdateAvailable(AppcastItem? appcastItem) {
    debugPrint('[Sparkle] 发现新版本：${appcastItem?.versionString}');
    _latestVersion = appcastItem?.versionString;
    _setStatus(SparkleUpdateStatus.idle);
  }

  @override
  void onUpdaterUpdateNotAvailable(UpdaterError? error) {
    debugPrint('[Sparkle] 当前已是最新版本');
    _latestVersion = null;
    _setStatus(SparkleUpdateStatus.upToDate);
  }

  @override
  void onUpdaterUpdateDownloaded(AppcastItem? appcastItem) {
    // 下载完成后的重启安装由 Sparkle 原生弹窗承担。
  }

  @override
  void onUpdaterBeforeQuitForUpdate(AppcastItem? appcastItem) {}

  void _setStatus(SparkleUpdateStatus status) {
    if (_status == status) return;
    _status = status;
    _statusController.add(status);
  }

  @visibleForTesting
  void reset() {
    _status = SparkleUpdateStatus.idle;
    _latestVersion = null;
    _initialized = false;
  }
}
