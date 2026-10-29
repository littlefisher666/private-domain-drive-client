import 'package:flutter/material.dart';

import '../../../../app/theme/cupertino_desktop.dart';
import '../../application/workspace_controller.dart';
import '../../domain/file_item.dart';
import 'cupertino_segmented.dart';
import 'detail_panel.dart';
import 'thumbnail_size_segmented.dart';

/// 桌面端工作区主体：顶部工具栏 + 左侧文件区域 + 右侧详情面板。
class WorkspaceDesktopBody extends StatelessWidget {
  const WorkspaceDesktopBody({
    super.key,
    required this.path,
    required this.canGoUp,
    required this.canUpload,
    required this.canDelete,
    required this.canDownload,
    required this.browseMode,
    required this.thumbnailSize,
    required this.sortOption,
    required this.selectedListenable,
    required this.directorySizeStatesListenable,
    this.filterController,
    this.filterQuery = '',
    this.onFilterChanged,
    required this.listArea,
    required this.onGoUp,
    required this.onRefresh,
    required this.onCreateFolder,
    required this.onUpload,
    required this.onUploadDirectory,
    required this.onBrowseModeChanged,
    required this.onThumbnailSizeChanged,
    required this.onSortChanged,
    required this.onOpen,
    required this.onPreview,
    required this.onDownload,
    required this.onDelete,
    this.detailBuilder,
    this.showPermissionNotice = true,
  });

  final String path;
  final bool canGoUp;
  final bool canUpload;
  final bool canDelete;
  final bool canDownload;
  final BrowseMode browseMode;
  final ThumbnailSize thumbnailSize;
  final FileSortOption sortOption;
  final ValueNotifier<FileItem?> selectedListenable;
  final ValueNotifier<Map<String, DirectorySizeState>>
      directorySizeStatesListenable;
  final TextEditingController? filterController;
  final String filterQuery;
  final ValueChanged<String>? onFilterChanged;
  final Widget listArea;
  final VoidCallback onGoUp;
  final VoidCallback onRefresh;
  final VoidCallback onCreateFolder;
  final VoidCallback onUpload;
  final VoidCallback onUploadDirectory;
  final ValueChanged<BrowseMode> onBrowseModeChanged;
  final ValueChanged<ThumbnailSize> onThumbnailSizeChanged;
  final ValueChanged<FileSortOption> onSortChanged;
  final ValueChanged<FileItem> onOpen;
  final ValueChanged<FileItem> onPreview;
  final ValueChanged<FileItem> onDownload;
  final ValueChanged<FileItem> onDelete;
  final Widget Function(FileItem?)? detailBuilder;
  final bool showPermissionNotice;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 工具栏控件统一 32 高，避免按钮、分段控件与筛选框参差。
    final toolbarOutlinedStyle = OutlinedButton.styleFrom(
      foregroundColor: scheme.onSurface,
      backgroundColor: scheme.surfaceContainerHighest,
      side: BorderSide.none,
      minimumSize: const Size(0, 32),
      maximumSize: const Size(double.infinity, 32),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      visualDensity: VisualDensity.standard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        height: 1.2,
      ),
    );
    final toolbarFilledStyle = FilledButton.styleFrom(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 0,
      minimumSize: const Size(0, 32),
      maximumSize: const Size(double.infinity, 32),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      visualDensity: VisualDensity.standard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        height: 1.2,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  if (canGoUp) ...<Widget>[
                    OutlinedButton(
                      style: toolbarOutlinedStyle,
                      onPressed: onGoUp,
                      child: const Text('‹ 上级'),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  CupertinoSegmented(
                    browseMode: browseMode,
                    onChanged: onBrowseModeChanged,
                  ),
                  if (browseMode == BrowseMode.grid)
                    ThumbnailSizeSegmented(
                      thumbnailSize: thumbnailSize,
                      onChanged: onThumbnailSizeChanged,
                    ),
                  if (filterController != null && onFilterChanged != null)
                    SizedBox(
                      width: 220,
                      height: 32,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: scheme.outline),
                        ),
                        child: Row(
                          children: <Widget>[
                            const SizedBox(width: 8),
                            Icon(
                              Icons.search,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              // 字体行盒下重，底边留白让文字与图标视觉居中。
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: TextField(
                                  controller: filterController,
                                  onChanged: onFilterChanged,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.2,
                                  ),
                                  textAlignVertical: TextAlignVertical.center,
                                  decoration: InputDecoration(
                                    hintText: '筛选当前目录',
                                    hintStyle: TextStyle(
                                      fontSize: 13,
                                      height: 1.2,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    filled: false,
                                    isDense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ),
                            if (filterQuery.isNotEmpty)
                              InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () {
                                  filterController!.clear();
                                  onFilterChanged!('');
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Icon(
                                    Icons.clear,
                                    size: 14,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            const SizedBox(width: 6),
                          ],
                        ),
                      ),
                    ),
                  PopupMenuButton<FileSortOption>(
                    tooltip: '排序',
                    onSelected: onSortChanged,
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    elevation: 10,
                    shadowColor: Colors.black26,
                    offset: const Offset(0, 42),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    itemBuilder: (context) => FileSortOption.values
                        .map(
                          (option) => CheckedPopupMenuItem<FileSortOption>(
                            value: option,
                            checked: option == sortOption,
                            child: Text(option.label),
                          ),
                        )
                        .toList(growable: false),
                    // 保持与“刷新”等工具栏按钮同一视觉语言；点击由外层菜单处理。
                    child: IgnorePointer(
                      child: OutlinedButton.icon(
                        style: toolbarOutlinedStyle,
                        onPressed: () {},
                        icon: const Icon(Icons.sort, size: 18),
                        label: Text('排序：${sortOption.shortLabel}'),
                      ),
                    ),
                  ),
                  OutlinedButton(
                    style: toolbarOutlinedStyle,
                    onPressed: onRefresh,
                    child: const Text('刷新'),
                  ),
                  if (canUpload) ...<Widget>[
                    OutlinedButton(
                      style: toolbarOutlinedStyle,
                      onPressed: onCreateFolder,
                      child: const Text('新建文件夹'),
                    ),
                    FilledButton(
                      style: toolbarFilledStyle,
                      onPressed: onUpload,
                      child: const Text('上传文件'),
                    ),
                    FilledButton(
                      style: toolbarFilledStyle,
                      onPressed: onUploadDirectory,
                      child: const Text('上传文件夹'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (showPermissionNotice &&
                        (!canUpload || !canDelete)) ...<Widget>[
                      Container(
                        margin: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: CupertinoDesktopTokens.noteBg,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          '当前用户缺少上传或删除权限。',
                          style: TextStyle(
                            color: CupertinoDesktopTokens.noteFg,
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                    Expanded(child: listArea),
                  ],
                ),
              ),
              SizedBox(
                width: CupertinoDesktopTokens.previewWidth,
                child: ValueListenableBuilder<FileItem?>(
                  valueListenable: selectedListenable,
                  builder: (context, current, _) {
                    return ValueListenableBuilder<
                        Map<String, DirectorySizeState>>(
                      valueListenable: directorySizeStatesListenable,
                      builder: (context, directorySizes, _) =>
                          detailBuilder?.call(current) ??
                          DetailPanel(
                            item: current,
                            directorySize:
                                current == null || !current.isDirectory
                                    ? null
                                    : directorySizes[current.path],
                          ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
