import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/state/app_scope.dart';
import '../infrastructure/github_release_client.dart';
import '../infrastructure/macos_sparkle_updater.dart';

/// 强制升级拦截页：门禁生效时由应用外壳（`MaterialApp.builder`）整体
/// 替换正常界面，不可跳过。仅提供升级、重试与退出应用三个出口。
///
/// Android 返回键被拦截：应用外壳替换后全局 Navigator 不在树中，系统返回
/// 事件不会进入任何路由的弹栈链路；本页作为 [WidgetsBindingObserver] 直接
/// 吞掉返回事件，`PopScope(canPop: false)` 同时让框架向系统声明由框架处理
/// 返回（前台时不会因系统默认行为直接关闭应用）。
class ForcedUpgradePage extends StatefulWidget {
  const ForcedUpgradePage({super.key});

  @override
  State<ForcedUpgradePage> createState() => _ForcedUpgradePageState();
}

enum _UpgradePhase { idle, downloading, failed }

class _ForcedUpgradePageState extends State<ForcedUpgradePage>
    with WidgetsBindingObserver {
  _UpgradePhase _phase = _UpgradePhase.idle;
  double? _downloadProgress;
  String? _errorMessage;
  String? _notice;
  bool _sparkleChecking = false;
  StreamSubscription<SparkleUpdateStatus>? _sparkleSubscription;

  bool get _isMacOS => defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isMacOS) {
      _sparkleSubscription =
          MacosSparkleUpdater.instance.statusStream.listen(_onSparkleStatus);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sparkleSubscription?.cancel();
    super.dispose();
  }

  /// 拦截期间吞掉系统返回，返回键不可绕过拦截。
  @override
  Future<bool> didPopRoute() async => true;

  void _onSparkleStatus(SparkleUpdateStatus status) {
    if (!mounted) return;
    switch (status) {
      case SparkleUpdateStatus.failed:
        setState(() {
          _sparkleChecking = false;
          _phase = _UpgradePhase.failed;
          _errorMessage = '无法连接更新服务器，请检查网络后重试';
        });
      case SparkleUpdateStatus.checking:
        break;
      case SparkleUpdateStatus.idle:
      case SparkleUpdateStatus.upToDate:
        // Sparkle 弹窗交互结束（含用户跳过更新）：恢复按钮可用。
        if (_sparkleChecking) {
          setState(() => _sparkleChecking = false);
        }
    }
  }

  Future<void> _startUpgrade() async {
    final controller = AppScope.read(context);
    setState(() {
      _phase = _UpgradePhase.idle;
      _errorMessage = null;
      _notice = null;
      _downloadProgress = null;
    });
    if (_isMacOS) {
      await _startSparkleUpgrade();
      return;
    }
    final update = controller.settingsController.forcedUpgradeResult?.availableUpdate;
    if (update == null) {
      _fail('暂未找到适用于当前设备的更新包，请使用「手动下载」升级');
      return;
    }
    setState(() {
      _phase = _UpgradePhase.downloading;
      _downloadProgress = 0;
    });
    try {
      await for (final progress
          in controller.settingsController.updateService.downloadAndroid(update)) {
        if (!mounted) return;
        setState(() => _downloadProgress = progress.fraction);
      }
      if (!mounted) return;
      setState(() {
        _phase = _UpgradePhase.idle;
        _downloadProgress = null;
        _notice = '已发起安装，请在系统弹窗中确认完成安装';
      });
    } catch (error) {
      debugPrint('[强制升级] 更新包下载/安装失败：$error');
      if (mounted) {
        _fail(error
            .toString()
            .replaceFirst(RegExp(r'^(\w*Exception: |Bad state: )'), ''));
      }
    }
  }

  Future<void> _startSparkleUpgrade() async {
    setState(() {
      _sparkleChecking = true;
      _errorMessage = null;
      _notice = null;
    });
    try {
      await MacosSparkleUpdater.instance.checkManually();
    } catch (error) {
      debugPrint('[强制升级] Sparkle 检查失败：$error');
      if (!mounted) return;
      setState(() {
        _sparkleChecking = false;
        _phase = _UpgradePhase.failed;
        _errorMessage = '无法发起升级，请检查网络后重试';
      });
    }
  }

  /// 重新检查门禁：不再满足强制条件时由应用外壳解除拦截；仍满足或检查
  /// 失败时页面保持拦截。
  Future<void> _retryGate() async {
    final controller = AppScope.read(context);
    setState(() {
      _phase = _UpgradePhase.idle;
      _errorMessage = null;
      _notice = null;
      _downloadProgress = null;
      _sparkleChecking = false;
    });
    await controller.settingsController.checkForcedUpgradeGate();
  }

  Future<void> _openReleasesPage() async {
    final url = Uri.parse(GithubReleaseClient.releasesPageUrl);
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (error) {
      debugPrint('[强制升级] 打开 GitHub 发布页失败：$error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开浏览器，请手动访问 GitHub Releases')),
        );
      }
    }
  }

  Future<void> _exitApp() async {
    if (_isMacOS) {
      exit(0);
    }
    await SystemNavigator.pop();
  }

  void _fail(String message) {
    setState(() {
      _phase = _UpgradePhase.failed;
      _errorMessage = message;
      _downloadProgress = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final result = controller.settingsController.forcedUpgradeResult;
    if (result == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final downloading = _phase == _UpgradePhase.downloading;
    final busy = downloading || _sparkleChecking;
    final notes = result.availableUpdate?.release.notes ?? '';

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Container(
              width: 360,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: scheme.outlineVariant),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: scheme.shadow.withValues(alpha: 0.18),
                    blurRadius: 30,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 68,
                    height: 68,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[Color(0xFF4DA3FF), Color(0xFF007AFF)],
                      ),
                    ),
                    child: const Icon(
                      Icons.system_update_alt,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('需要升级', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    '当前版本已低于最低支持版本，请升级后继续使用。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(
                        '当前版本',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      Text(
                        result.currentVersion,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(
                        '最低支持版本',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      Text(
                        result.minSupportedVersion ?? '',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  if (notes.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 120),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          notes,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ],
                  if (downloading) ...<Widget>[
                    const SizedBox(height: 20),
                    LinearProgressIndicator(value: _downloadProgress),
                    const SizedBox(height: 8),
                    Text(
                      _downloadProgress == null
                          ? '正在下载…'
                          : '正在下载… ${(_downloadProgress! * 100).toStringAsFixed(0)}%',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  if (_sparkleChecking) ...<Widget>[
                    const SizedBox(height: 20),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text('正在检查更新…', style: theme.textTheme.bodySmall),
                  ],
                  if (_notice != null) ...<Widget>[
                    const SizedBox(height: 16),
                    Text(
                      _notice!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                  if (_errorMessage != null) ...<Widget>[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '升级失败：$_errorMessage',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onErrorContainer),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: busy ? null : _startUpgrade,
                      child: Text(downloading ? '正在下载…' : '立即升级'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: busy ? null : _retryGate,
                          child: const Text('重试'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _openReleasesPage,
                          child: const Text('手动下载'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: busy ? null : _exitApp,
                    child: const Text('退出应用'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
