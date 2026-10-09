import 'dart:async';

import 'package:auto_updater/auto_updater.dart';
import 'package:flutter/foundation.dart';

bool usesSparkleUpdate(TargetPlatform platform) =>
    platform == TargetPlatform.macOS;

enum SparkleUpdateStatus { idle, checking, upToDate, failed }

/// 正在进行的一次更新检查来源。
enum _CheckKind { none, startup, manual }

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
  _CheckKind _activeCheck = _CheckKind.none;

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

  /// 启动后的静默检查；Sparkle 自动检查失败时不打扰用户，回到空闲状态。
  ///
  /// 升级自动重启后 Sparkle 的安装会话可能尚未收尾，此时发起的检查会被
  /// Sparkle 拒绝并以上报 error 事件，因此失败一律静默处理。
  Future<void> startupCheck() async {
    await initialize();
    _activeCheck = _CheckKind.startup;
    unawaited(_api.checkForUpdates(inBackground: true));
  }

  /// 设置页手动检查；发现更新或已是最新时由 Sparkle 原生弹窗反馈。
  Future<void> checkManually() async {
    await initialize();
    _activeCheck = _CheckKind.manual;
    _setStatus(SparkleUpdateStatus.checking);
    await _api.checkForUpdates(inBackground: false);
  }

  @override
  void onUpdaterError(UpdaterError? error) {
    debugPrint('[Sparkle] 更新检查失败：${error?.message}');
    final kind = _activeCheck;
    _activeCheck = _CheckKind.none;
    if (kind == _CheckKind.manual) {
      _setStatus(SparkleUpdateStatus.failed);
    } else if (kind == _CheckKind.startup) {
      // 启动静默检查失败：不打扰用户，回到空闲状态。
      _setStatus(SparkleUpdateStatus.idle);
    }
    // 无进行中的检查（游离的会话中止事件）：忽略。
  }

  @override
  void onUpdaterCheckingForUpdate(Appcast? appcast) {
    // appcast 加载完成，等待后续 available / not-available 事件。
  }

  @override
  void onUpdaterUpdateAvailable(AppcastItem? appcastItem) {
    debugPrint('[Sparkle] 发现新版本：${appcastItem?.displayVersionString}');
    // versionString 是构建号，用户可读的营销版本号在 displayVersionString。
    _latestVersion = appcastItem?.displayVersionString ?? appcastItem?.versionString;
    _activeCheck = _CheckKind.none;
    _setStatus(SparkleUpdateStatus.idle);
  }

  @override
  void onUpdaterUpdateNotAvailable(UpdaterError? error) {
    debugPrint('[Sparkle] 当前已是最新版本');
    _latestVersion = null;
    _activeCheck = _CheckKind.none;
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
    _activeCheck = _CheckKind.none;
  }
}
