import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/version/app_version.dart';
import '../infrastructure/github_release_client.dart';
import 'update_service.dart';

/// 设置域控制器：主题模式、自动检查更新偏好与强制升级门禁。
///
/// 持有 [updateService] 单例，设置页与强制升级拦截页共享同一实例
/// （检查结果口径一致）；偏好经 SharedPreferences 持久化并在启动恢复。
class SettingsController extends ChangeNotifier {
  SettingsController({
    UpdateService? updateService,
    bool? disableStartupUpdateCheck,
  })  : _updateService = updateService ??
            UpdateService(
              versionReader: PackageAppVersionReader(),
              releaseClient: GithubReleaseClient(),
            ),
        _disableStartupUpdateCheck =
            disableStartupUpdateCheck ?? AppConstants.disableStartupUpdateCheck;

  static const _themeModeKey = 'theme_mode';
  static const _autoCheckUpdatesKey = 'auto_check_updates';

  /// 更新服务与设置页、强制升级拦截页共享同一实例（检查结果口径一致）。
  UpdateService get updateService => _updateService;
  final UpdateService _updateService;
  final bool _disableStartupUpdateCheck;

  ThemeMode _themeMode = ThemeMode.light;
  bool _autoCheckUpdates = true;

  /// 强制升级门禁检查结果；非空表示当前版本低于最低支持版本、拦截生效。
  UpdateCheckResult? _forcedUpgradeResult;
  bool _forcedUpgradeChecking = false;

  SharedPreferences? _preferences;

  ThemeMode get themeMode => _themeMode;

  /// 是否在启动时自动检查更新（仅 macOS Sparkle 路径消费）。
  bool get autoCheckUpdates => _autoCheckUpdates;

  /// 更新显示模式；偏好会在下次启动时恢复。
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) {
      return;
    }
    _themeMode = mode;
    notifyListeners();
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setString(_themeModeKey, mode.name);
    } catch (_) {
      // 偏好写入失败时仍保留本次会话的选择。
    }
  }

  /// 更新启动自动检查偏好；写入失败时保留本次会话的选择。
  Future<void> setAutoCheckUpdates(bool value) async {
    if (_autoCheckUpdates == value) {
      return;
    }
    _autoCheckUpdates = value;
    notifyListeners();
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setBool(_autoCheckUpdatesKey, value);
    } catch (_) {
      // 偏好写入失败时仍保留本次会话的选择。
    }
  }

  /// 启动恢复：主题模式与自动检查更新偏好；读取失败由调用方兜底。
  void restorePreferences(SharedPreferences preferences) {
    _preferences = preferences;
    _themeMode = switch (preferences.getString(_themeModeKey)) {
      'dark' => ThemeMode.dark,
      _ => ThemeMode.light,
    };
    _autoCheckUpdates = preferences.getBool(_autoCheckUpdatesKey) ?? true;
  }

  /// 强制升级拦截是否生效；生效时应用外壳以强制升级页替换整棵界面。
  bool get forcedUpgradeActive => _forcedUpgradeResult != null;

  /// 拦截生效时的检查结果（当前版本、最低支持版本与可用升级资产）。
  UpdateCheckResult? get forcedUpgradeResult => _forcedUpgradeResult;

  /// 启动静默检查与拦截页「重试」共用的门禁检查：成功后按结果更新门禁
  /// 状态；失败（离线、超时、响应异常）静默放行且不缓存结论，下一次启动
  /// 或重试时重新检查。不受 macOS「启动时自动检查更新」开关约束，
  /// 仅受编译期调试开关 `DISABLE_STARTUP_UPDATE_CHECK` 约束。
  Future<void> checkForcedUpgradeGate() async {
    if (_disableStartupUpdateCheck || _forcedUpgradeChecking) return;
    _forcedUpgradeChecking = true;
    try {
      final result = await _updateService.checkLatest();
      final forced = result.requiresForcedUpgrade;
      _forcedUpgradeResult = forced ? result : null;
      debugPrint(forced
          ? '[强制升级] 当前版本 ${result.currentVersion} 低于最低支持版本 '
              '${result.minSupportedVersion}，进入拦截'
          : '[强制升级] 门禁检查通过，当前版本 ${result.currentVersion}');
    } catch (error, stackTrace) {
      debugPrint('[强制升级] 门禁检查失败，放行：$error');
      debugPrintStack(stackTrace: stackTrace, label: '[强制升级] 门禁检查异常堆栈');
      // 失败不改变门禁状态：启动阶段保持放行，拦截期间保持拦截。
      return;
    } finally {
      _forcedUpgradeChecking = false;
      notifyListeners();
    }
  }
}
