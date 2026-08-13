import 'package:flutter/material.dart';

import '../../../app/theme/cupertino_desktop.dart';
import '../../../shared/state/app_scope.dart';
import '../../settings/presentation/settings_page.dart';
import '../../transfer/presentation/transfer_tasks_page.dart';
import 'workspace_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _index = widget.initialIndex.clamp(0, 2);

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final desktop = width >= 960;

    if (desktop) {
      return Theme(
        data: CupertinoDesktopTheme.light(),
        child: _DesktopShell(
          index: _index,
          onSelect: (value) => setState(() => _index = value),
        ),
      );
    }

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const <Widget>[
          WorkspacePage(),
          TransferTasksPage(embedded: true),
          SettingsPage(embedded: true),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
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
    required this.onSelect,
  });

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final session = controller.session;
    final theme = Theme.of(context);
    final title = switch (index) {
      1 => '传输中心',
      2 => '我的',
      _ => '私域网盘',
    };

    return Scaffold(
      backgroundColor: CupertinoDesktopTokens.background,
      body: Column(
        children: <Widget>[
          _DesktopTitleBar(
            title: title,
            showUpload: index == 0 && controller.capabilities.upload,
            onUpload: () {
              onSelect(0);
              final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
              controller.mockUpload(
                fileName: "upload-$stamp.bin",
                size: 640 * 1024,
              );
            },
          ),
          Expanded(
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: CupertinoDesktopTokens.sidebarWidth,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: CupertinoDesktopTokens.sidebar,
                      border: Border(
                        right: BorderSide(color: CupertinoDesktopTokens.line),
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
                              onTap: () => onSelect(0),
                            ),
                            _SideNavItem(
                              selected: index == 1,
                              icon: Icons.swap_vert,
                              label: '传输中心',
                              onTap: () => onSelect(1),
                            ),
                            const SizedBox(height: 14),
                            Text('目录', style: theme.textTheme.labelLarge),
                            const SizedBox(height: 6),
                            Expanded(
                              child: ListView(
                                padding: EdgeInsets.zero,
                                children: controller.sidebarDirectories.map((path) {
                                  final selected =
                                      controller.currentPath == path && index == 0;
                                  final label = path == 'shared/'
                                      ? 'shared/'
                                      : path.replaceFirst('shared/', '');
                                  return _SideNavItem(
                                    selected: selected,
                                    icon: Icons.circle,
                                    iconSize: 8,
                                    label: label,
                                    onTap: () {
                                      controller.setCurrentPath(path);
                                      onSelect(0);
                                    },
                                  );
                                }).toList(),
                              ),
                            ),
                            Material(
                              color: Colors.white.withValues(alpha: 0.7),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                                side: const BorderSide(
                                  color: CupertinoDesktopTokens.line,
                                ),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => onSelect(2),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        session?.displayName ?? '未登录',
                                        style: theme.textTheme.titleSmall,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '共享空间成员',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                          color:
                                              CupertinoDesktopTokens.secondary,
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
                    color: CupertinoDesktopTokens.surface,
                    child: IndexedStack(
                      index: index,
                      children: const <Widget>[
                        WorkspacePage(desktopChrome: true),
                        TransferTasksPage(
                          embedded: true,
                          desktopChrome: true,
                        ),
                        SettingsPage(
                          embedded: true,
                          desktopChrome: true,
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
  const _DesktopTitleBar({
    required this.title,
    required this.showUpload,
    required this.onUpload,
  });

  final String title;
  final bool showUpload;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    // Leave space for native macOS traffic lights under fullSizeContentView.
    return Container(
      height: CupertinoDesktopTokens.titleBarHeight,
      padding: const EdgeInsets.fromLTRB(86, 0, 14, 0),
      decoration: const BoxDecoration(
        color: Color(0xB8FFFFFF),
        border: Border(
          bottom: BorderSide(color: CupertinoDesktopTokens.line),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF3A3A3C),
              ),
            ),
          ),
          SizedBox(
            width: 88,
            child: Align(
              alignment: Alignment.centerRight,
              child: showUpload
                  ? FilledButton(
                      onPressed: onUpload,
                      child: const Text('上传'),
                    )
                  : const SizedBox.shrink(),
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
              'PD',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '私域网盘',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: CupertinoDesktopTokens.ink,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '私域共享空间',
                  style: TextStyle(
                    fontSize: 11,
                    color: CupertinoDesktopTokens.secondary,
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
            ? CupertinoDesktopTokens.blue.withValues(alpha: 0.14)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          hoverColor: const Color(0x143C3C43),
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
                          ? CupertinoDesktopTokens.blue
                          : CupertinoDesktopTokens.ink,
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
                            ? CupertinoDesktopTokens.blue
                            : CupertinoDesktopTokens.ink,
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
