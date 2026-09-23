import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/router/route_names.dart';
import '../../../core/version/app_version.dart';
import '../../../shared/state/app_scope.dart';
import '../application/update_service.dart';
import '../infrastructure/github_release_client.dart';

RoundedRectangleBorder _mobileCardShape(ColorScheme scheme) {
  return RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
    side: BorderSide(color: scheme.outlineVariant),
  );
}

EdgeInsetsGeometry _mobileTilePadding(bool desktop) {
  return EdgeInsets.symmetric(horizontal: desktop ? 16 : 18);
}

double _mobileTileVerticalPadding(bool desktop) => desktop ? 4 : 10;

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _SettingsLeadingIcon extends StatelessWidget {
  const _SettingsLeadingIcon({required this.icon, required this.desktop});

  final IconData icon;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (desktop) return Icon(icon);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(11),
      ),
      child: SizedBox(
        width: 36,
        height: 36,
        child: Icon(icon, color: scheme.primary, size: 20),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage(
      {super.key,
      this.embedded = false,
      this.desktopChrome = false,
      this.visitToken = 0});

  final bool embedded;
  final bool desktopChrome;
  final int visitToken;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Future<AppVersion> _version = PackageAppVersionReader().read();
  late final UpdateService _updates = UpdateService(
    versionReader: PackageAppVersionReader(),
    releaseClient: GithubReleaseClient(),
  );
  UpdateCheckResult? _updateCheck;
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _refreshUpdateStatus();
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visitToken != oldWidget.visitToken) {
      _refreshUpdateStatus();
    }
  }

  Future<void> _refreshUpdateStatus() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final result = await _updates.checkLatest();
      if (mounted) setState(() => _updateCheck = result);
    } catch (error, stackTrace) {
      debugPrint('[更新检查] 自动检查失败：$error');
      debugPrintStack(stackTrace: stackTrace, label: '[更新检查] 自动检查异常堆栈');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final session = controller.session;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final desktop =
        widget.desktopChrome || MediaQuery.sizeOf(context).width >= 960;
    final displayName = session?.displayName ?? '';
    final initial = displayName.isNotEmpty
        ? displayName.substring(0, 1).toUpperCase()
        : 'U';

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            desktop ? 24 : 16,
            desktop ? 16 : 12,
            desktop ? 24 : 16,
            desktop ? 24 : 32,
          ),
          children: <Widget>[
            Row(
              children: <Widget>[
                if (!widget.embedded)
                  IconButton.filledTonal(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back),
                  ),
                if (!widget.embedded) const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '我的',
                        style: desktop
                            ? theme.textTheme.headlineSmall
                            : theme.textTheme.headlineMedium,
                      ),
                      if (desktop)
                        Text(
                          '账户与应用信息',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: desktop ? 16 : 20),
            if (!desktop)
              _SectionLabel(label: '账户', color: scheme.onSurfaceVariant),
            if (!desktop) const SizedBox(height: 8),
            Card(
              shape: desktop ? null : _mobileCardShape(scheme),
              child: ListTile(
                contentPadding: EdgeInsets.symmetric(
                  horizontal: desktop ? 16 : 18,
                  vertical: desktop ? 10 : 8,
                ),
                minVerticalPadding: 0,
                leading: CircleAvatar(
                  radius: desktop ? 26 : 28,
                  backgroundColor:
                      (desktop ? const Color(0xFF007AFF) : scheme.primary)
                          .withValues(alpha: 0.15),
                  child: Text(
                    initial,
                    style: TextStyle(
                      color: desktop ? const Color(0xFF007AFF) : scheme.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: desktop ? null : 20,
                    ),
                  ),
                ),
                title: Text(
                  session?.displayName ?? '未登录',
                  style: desktop ? null : theme.textTheme.titleMedium,
                ),
                subtitle:
                    session == null ? const Text('请先登录') : null,
              ),
            ),
            SizedBox(height: desktop ? 12 : 16),
            Card(
              shape: desktop ? null : _mobileCardShape(scheme),
              child: ListTile(
                contentPadding: _mobileTilePadding(desktop),
                minVerticalPadding: _mobileTileVerticalPadding(desktop),
                leading: _SettingsLeadingIcon(
                  icon: Icons.lock_outline,
                  desktop: desktop,
                ),
                title: const Text('修改密码'),
                subtitle: const Text('校验当前密码后设置新密码'),
                onTap: () => Navigator.of(context).pushNamed(
                  RouteNames.changePassword,
                  arguments: false,
                ),
              ),
            ),
            SizedBox(height: desktop ? 12 : 20),
            if (!desktop)
              _SectionLabel(label: '应用', color: scheme.onSurfaceVariant),
            if (!desktop) const SizedBox(height: 8),
            Card(
              shape: desktop ? null : _mobileCardShape(scheme),
              child: Column(
                children: <Widget>[
                  FutureBuilder<AppVersion>(
                    future: _version,
                    builder: (context, snapshot) => ListTile(
                      contentPadding: _mobileTilePadding(desktop),
                      minVerticalPadding: _mobileTileVerticalPadding(desktop),
                      leading: _SettingsLeadingIcon(
                        icon: Icons.info_outline,
                        desktop: desktop,
                      ),
                      title: const Text('应用版本'),
                      subtitle: Text(snapshot.data?.displayValue ?? '读取中…'),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: _mobileTilePadding(desktop),
                    minVerticalPadding: _mobileTileVerticalPadding(desktop),
                    leading: _SettingsLeadingIcon(
                      icon: Icons.system_update_outlined,
                      desktop: desktop,
                    ),
                    title: const Text('检查更新'),
                    subtitle: Text(_updateSubtitle),
                    trailing: _updateBadge,
                    onTap: _checkForUpdate,
                  ),
                ],
              ),
            ),
            SizedBox(height: desktop ? 16 : 20),
            if (desktop)
              Text('显示', style: theme.textTheme.titleMedium)
            else
              _SectionLabel(label: '显示', color: scheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Card(
              shape: desktop ? null : _mobileCardShape(scheme),
              child: Column(
                children: <Widget>[
                  ListTile(
                    contentPadding: _mobileTilePadding(desktop),
                    minVerticalPadding: _mobileTileVerticalPadding(desktop),
                    leading: _SettingsLeadingIcon(
                      icon: controller.themeMode == ThemeMode.light
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                      desktop: desktop,
                    ),
                    title: const Text('外观模式'),
                    subtitle: Text(
                      controller.themeMode == ThemeMode.dark ? '深色模式' : '浅色模式',
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      desktop ? 12 : 16,
                      12,
                      desktop ? 12 : 16,
                      desktop ? 12 : 16,
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<ThemeMode>(
                        segments: const <ButtonSegment<ThemeMode>>[
                          ButtonSegment<ThemeMode>(
                            value: ThemeMode.light,
                            icon: Icon(Icons.light_mode_outlined),
                            label: Text('浅色模式'),
                          ),
                          ButtonSegment<ThemeMode>(
                            value: ThemeMode.dark,
                            icon: Icon(Icons.dark_mode_outlined),
                            label: Text('深色模式'),
                          ),
                        ],
                        selected: <ThemeMode>{controller.themeMode},
                        onSelectionChanged: (modes) =>
                            controller.setThemeMode(modes.first),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: desktop ? 16 : 24),
            if (desktop)
              FilledButton.tonal(
                onPressed: _logout,
                child: const Text('退出登录'),
              )
            else
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.error,
                  side: BorderSide(
                    color: scheme.error.withValues(alpha: 0.35),
                  ),
                ),
                onPressed: _logout,
                child: const Text('退出登录'),
              ),
          ],
        ),
      ),
    );
  }

  String get _updateSubtitle {
    final result = _updateCheck;
    if (_checkingUpdate && result == null) return '正在检查最新版本…';
    if (result == null) return '从 GitHub Releases 获取稳定版';
    return '最新版本 ${result.latestVersion}';
  }

  Widget? get _updateBadge {
    if (_updateCheck?.availableUpdate == null) return null;
    return const Chip(
      label: Text('有新版本'),
      visualDensity: VisualDensity.compact,
    );
  }

  Future<void> _logout() async {
    await AppScope.of(context).logout();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      RouteNames.login,
      (route) => false,
    );
  }

  Future<void> _checkForUpdate() async {
    try {
      final result = await _updates.checkLatest();
      if (mounted) setState(() => _updateCheck = result);
      final update = result.availableUpdate;
      if (!mounted) return;
      if (update == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.hasUpdate ? '发现新版本，但当前平台暂无更新包' : '当前已是最新版本',
            ),
          ),
        );
        return;
      }
      final macos = defaultTargetPlatform == TargetPlatform.macOS;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('发现新版本 ${update.release.version}'),
          content: SingleChildScrollView(
              child: Text(
            '${update.release.notes.isEmpty ? '暂无更新说明。' : update.release.notes}\n\n${macos ? '下载 DMG 后，请将新版应用拖入“应用程序”文件夹覆盖旧版。' : '下载完成后将由系统确认安装。'}',
          )),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('稍后')),
            FilledButton(
                onPressed: () async {
                  Navigator.pop(context);
                  if (macos) {
                    await _updates.openDownload(update);
                  } else {
                    await _downloadAndInstall(update);
                  }
                },
                child: const Text('下载更新')),
          ],
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('[更新检查] 页面处理失败：$error');
      debugPrintStack(stackTrace: stackTrace, label: '[更新检查] 页面异常堆栈');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('检查更新失败，请稍后重试')));
      }
    }
  }

  Future<void> _downloadAndInstall(AvailableUpdate update) async {
    final progress = ValueNotifier<double?>(0);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('正在下载更新'),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: value),
              const SizedBox(height: 12),
              Text(value == null
                  ? '正在下载…'
                  : '${(value * 100).toStringAsFixed(0)}%'),
            ],
          ),
        ),
      ),
    );
    try {
      await for (final item in _updates.downloadAndroid(update)) {
        progress.value = item.fraction;
      }
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    } catch (error) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      progress.dispose();
    }
  }
}
