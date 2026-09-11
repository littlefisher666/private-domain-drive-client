import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/router/route_names.dart';
import '../../../core/version/app_version.dart';
import '../../../shared/state/app_scope.dart';
import '../application/update_service.dart';
import '../infrastructure/github_release_client.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage(
      {super.key, this.embedded = false, this.desktopChrome = false});

  final bool embedded;
  final bool desktopChrome;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Future<AppVersion> _version = PackageAppVersionReader().read();
  late final UpdateService _updates = UpdateService(
    versionReader: PackageAppVersionReader(),
    releaseClient: GithubReleaseClient(),
  );

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
          padding:
              EdgeInsets.fromLTRB(desktop ? 24 : 16, 16, desktop ? 24 : 16, 24),
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
                      Text('我的', style: theme.textTheme.headlineSmall),
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
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  radius: 26,
                  backgroundColor:
                      (desktop ? const Color(0xFF007AFF) : scheme.primary)
                          .withValues(alpha: 0.15),
                  child: Text(
                    initial,
                    style: TextStyle(
                      color: desktop ? const Color(0xFF007AFF) : scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                title: Text(session?.displayName ?? '未登录'),
                subtitle: Text(
                  session == null
                      ? '请先登录'
                      : "成员 · ${session.capabilities.summary}",
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: Icon(Icons.folder_shared_outlined),
                    title: Text('共享空间'),
                    subtitle: Text('文件与目录'),
                  ),
                  Divider(height: 1),
                  FutureBuilder<AppVersion>(
                    future: _version,
                    builder: (context, snapshot) => ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('应用版本'),
                      subtitle: Text(snapshot.data?.displayValue ?? '读取中…'),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.system_update_outlined),
                    title: const Text('检查更新'),
                    subtitle: const Text('从 GitHub Releases 获取稳定版'),
                    onTap: _checkForUpdate,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text('显示', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: Icon(
                      controller.themeMode == ThemeMode.light
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                    ),
                    title: const Text('外观模式'),
                    subtitle: Text(
                      controller.themeMode == ThemeMode.dark ? '深色模式' : '浅色模式',
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(12),
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
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () async {
                await controller.logout();
                if (!context.mounted) {
                  return;
                }
                Navigator.of(context).pushNamedAndRemoveUntil(
                  RouteNames.login,
                  (route) => false,
                );
              },
              child: const Text('退出登录'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkForUpdate() async {
    try {
      final update = await _updates.check();
      if (!mounted) return;
      if (update == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('当前已是最新版本')));
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
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('检查更新失败，请稍后重试')));
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
