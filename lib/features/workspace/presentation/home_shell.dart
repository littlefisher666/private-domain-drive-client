import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../../../app/theme/cupertino_desktop.dart';
import '../../../shared/state/app_scope.dart';
import '../../settings/presentation/settings_page.dart';
import '../../transfer/presentation/transfer_tasks_page.dart';
import 'workspace_page.dart';
import 'recycle_bin_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _index = widget.initialIndex.clamp(0, 3);
  int _settingsVisit = 0;
  int _recycleBinVisit = 0;

  void _select(int value) {
    if (value == 2) _recycleBinVisit++;
    if (value == 3) _settingsVisit++;
    setState(() => _index = value);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final desktop = width >= 960;

    if (desktop) {
      return _DesktopShell(
        index: _index,
        settingsVisit: _settingsVisit,
        recycleBinVisit: _recycleBinVisit,
        onSelect: _select,
      );
    }

    return Scaffold(
      body: IndexedStack(
        index: _index.clamp(0, 3),
        children: <Widget>[
          const WorkspacePage(),
          const TransferTasksPage(embedded: true),
          RecycleBinPage(
            key: ValueKey<String>('recycle-bin-mobile-$_recycleBinVisit'),
            embedded: true,
            visitToken: _recycleBinVisit,
          ),
          SettingsPage(embedded: true, visitToken: _settingsVisit),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: '文件',
          ),
          NavigationDestination(
            icon: Icon(Icons.swap_vert_circle_outlined),
            selectedIcon: Icon(Icons.swap_vert_circle),
            label: '传输',
          ),
          NavigationDestination(
            icon: Icon(CupertinoIcons.trash),
            selectedIcon: Icon(CupertinoIcons.trash_fill),
            label: '回收站',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

class _DesktopShell extends StatelessWidget {
  const _DesktopShell({
    required this.index,
    required this.settingsVisit,
    required this.recycleBinVisit,
    required this.onSelect,
  });

  final int index;
  final int settingsVisit;
  final int recycleBinVisit;
  final ValueChanged<int> onSelect;

  void _selectPage(int value) {
    FocusManager.instance.primaryFocus?.unfocus();
    onSelect(value);
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final session = controller.session;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = switch (index) {
      1 => '传输中心',
      2 => '回收站',
      3 => '我的',
      _ => '私域网盘',
    };

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Column(
        children: <Widget>[
          _DesktopTitleBar(title: title),
          Expanded(
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: CupertinoDesktopTokens.sidebarWidth,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      border: Border(
                        right: BorderSide(color: scheme.outlineVariant),
                      ),
                    ),
                    child: SafeArea(
                      right: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            const _BrandHeader(),
                            const SizedBox(height: 14),
                            Text('功能', style: theme.textTheme.labelLarge),
                            const SizedBox(height: 6),
                            _SideNavItem(
                              selected: index == 0,
                              icon: Icons.folder_outlined,
                              label: '共享空间',
                              onTap: () => _selectPage(0),
                            ),
                            _SideNavItem(
                              selected: index == 1,
                              icon: Icons.swap_vert,
                              label: '传输中心',
                              onTap: () => _selectPage(1),
                            ),
                            _SideNavItem(
                              selected: index == 2,
                              icon: CupertinoIcons.trash,
                              label: '回收站',
                              onTap: () => _selectPage(2),
                            ),
                            const SizedBox(height: 14),
                            Text('目录', style: theme.textTheme.labelLarge),
                            const SizedBox(height: 6),
                            Expanded(
                              child: ListView(
                                padding: EdgeInsets.zero,
                                children:
                                    controller.sidebarDirectories.map((path) {
                                  final selected =
                                      controller.currentPath == path &&
                                          index == 0;
                                  final label = controller.displayPath(path);
                                  return _SideNavItem(
                                    selected: selected,
                                    icon: Icons.circle,
                                    iconSize: 8,
                                    label: label,
                                    onTap: () {
                                      controller.setCurrentPath(path);
                                      _selectPage(0);
                                    },
                                  );
                                }).toList(),
                              ),
                            ),
                            Material(
                              color: scheme.surface,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                                side: BorderSide(color: scheme.outlineVariant),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => _selectPage(3),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        session?.displayName ?? '未登录',
                                        style: theme.textTheme.titleSmall,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '共享空间成员',
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ColoredBox(
                    color: scheme.surface,
                    child: IndexedStack(
                      index: index,
                      children: <Widget>[
                        const WorkspacePage(desktopChrome: true),
                        const TransferTasksPage(
                          embedded: true,
                          desktopChrome: true,
                        ),
                        RecycleBinPage(
                          key: ValueKey<String>('recycle-bin-$recycleBinVisit'),
                          embedded: true,
                          visitToken: recycleBinVisit,
                        ),
                        SettingsPage(
                          embedded: true,
                          desktopChrome: true,
                          visitToken: settingsVisit,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopTitleBar extends StatelessWidget {
  const _DesktopTitleBar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    // Leave space for native macOS traffic lights under fullSizeContentView.
    return Container(
      height: CupertinoDesktopTokens.titleBarHeight,
      padding: const EdgeInsets.fromLTRB(86, 0, 14, 0),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.88),
        border: Border(
          bottom:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Color(0xFF4DA3FF), Color(0xFF007AFF)],
              ),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x3D007AFF),
                  blurRadius: 16,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: const Text(
              'PDD',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '私域网盘',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'PRIVATE DOMAIN DRIVE',
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.35,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SideNavItem extends StatelessWidget {
  const _SideNavItem({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconSize = 18,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.14)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          hoverColor:
              Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
          child: SizedBox(
            height: 34,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 18,
                    child: Icon(
                      icon,
                      size: iconSize,
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
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
