import 'package:flutter/material.dart';

import '../../domain/file_item.dart';

/// 移动端顶部标题栏：路径、角色、返回/排序/浏览模式切换/刷新。
class WorkspaceMobileHeader extends StatelessWidget {
  const WorkspaceMobileHeader({
    super.key,
    required this.path,
    required this.roleLabel,
    required this.canGoUp,
    required this.browseMode,
    required this.sortOption,
    required this.onGoUp,
    required this.onRefresh,
    required this.onBrowseModeChanged,
    required this.onChooseSort,
    this.filterController,
    this.filterQuery = '',
    this.onFilterChanged,
    this.filterExpanded = false,
    this.onToggleFilter,
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
  final TextEditingController? filterController;
  final String filterQuery;
  final ValueChanged<String>? onFilterChanged;
  final bool filterExpanded;
  final VoidCallback? onToggleFilter;
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
                visualDensity: VisualDensity.compact,
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: theme.textTheme.headlineSmall,
                  ),
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
            if (onToggleFilter != null)
              IconButton(
                onPressed: onToggleFilter,
                icon: Icon(filterExpanded ? Icons.search_off : Icons.search),
                tooltip: filterExpanded ? '关闭筛选' : '筛选当前目录',
                visualDensity: VisualDensity.compact,
              ),
            IconButton(
              onPressed: onChooseSort,
              icon: const Icon(Icons.sort),
              tooltip: '排序：${sortOption.label}',
              visualDensity: VisualDensity.compact,
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
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        if (filterExpanded &&
            filterController != null &&
            onFilterChanged != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: filterController,
              onChanged: onFilterChanged,
              autofocus: true,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: '筛选当前目录',
                prefixIcon: const Icon(Icons.search, size: 18),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 34,
                  minHeight: 34,
                ),
                suffixIcon: filterQuery.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除筛选',
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          filterController!.clear();
                          onFilterChanged!('');
                        },
                      ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
