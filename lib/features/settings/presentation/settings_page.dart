import 'package:flutter/material.dart';

import '../../../app/router/route_names.dart';
import '../../../shared/state/app_scope.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage(
      {super.key, this.embedded = false, this.desktopChrome = false});

  final bool embedded;
  final bool desktopChrome;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final session = controller.session;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final desktop = desktopChrome || MediaQuery.sizeOf(context).width >= 960;
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
                if (!embedded)
                  IconButton.filledTonal(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back),
                  ),
                if (!embedded) const SizedBox(width: 12),
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
            const Card(
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: Icon(Icons.folder_shared_outlined),
                    title: Text('共享空间'),
                    subtitle: Text('文件与目录'),
                  ),
                  Divider(height: 1),
                  ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('应用版本'),
                    subtitle: Text('0.1.0+1'),
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
}
