import 'package:flutter/material.dart';

import '../../../app/router/route_names.dart';
import '../../../shared/state/app_scope.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, this.embedded = false, this.desktopChrome = false});

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
    final initial = displayName.isNotEmpty ? displayName.substring(0, 1).toUpperCase() : 'U';

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(desktop ? 24 : 16, 16, desktop ? 24 : 16, 24),
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
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
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
                      (desktop ? const Color(0xFF007AFF) : scheme.primary).withValues(alpha: 0.15),
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
                    leading: const Icon(Icons.folder_shared_outlined),
                    title: const Text('共享空间'),
                    subtitle: Text(session?.rootPrefix ?? 'shared/'),
                  ),
                  const Divider(height: 1),
                  const ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('应用版本'),
                    subtitle: Text('0.1.0+1'),
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
