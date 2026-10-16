import 'package:flutter/material.dart';

import '../../domain/file_item.dart';

/// 移动端顶部标题栏：路径、角色、返回/排序/浏览模式切换/刷新。
class WorkspaceMobileHeader extends StatelessWidget {
  const WorkspaceMobileHeader({
    required this.path,
    required this.roleLabel,
    required this.canGoUp,
    required this.browseMode,
    required this.sortOption,
    required this.onGoUp,
    required this.onRefresh,
    required this.onBrowseModeChanged,
    required this.onChooseSort,
    this.title = '共享空间',
  });

  final String path;
  final String roleLabel;
  final bool canGoUp;
  final BrowseMode browseMode;
  final FileSortOption sortOption;
  final VoidCallback onGoUp;
  final VoidCallback onRefresh;
  final ValueChanged<BrowseMode> onBrowseModeChanged;
  final VoidCallback onChooseSort;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            if (canGoUp)
              IconButton(
                onPressed: onGoUp,
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回上级',
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 2),
                  Text(
                    '$roleLabel · $path',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onChooseSort,
              icon: const Icon(Icons.sort),
              tooltip: '排序：${sortOption.label}',
            ),
            IconButton(
              onPressed: () => onBrowseModeChanged(
                browseMode == BrowseMode.list
                    ? BrowseMode.grid
                    : BrowseMode.list,
              ),
              icon: Icon(browseMode == BrowseMode.list
                  ? Icons.grid_view
                  : Icons.view_list),
              tooltip: browseMode == BrowseMode.list ? '切换为缩略图' : '切换为列表',
            ),
            IconButton(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
            ),
          ],
        ),
      ],
    );
  }
}
