import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../shared/widgets/file_icon.dart';
import '../../domain/file_item.dart';
import 'desktop_item_menu.dart';
import 'desktop_marquee_selection.dart';
import 'hover_checkbox.dart';
import 'inline_rename_field.dart';
import 'mobile_uniform_grid.dart';

/// 工作区网格视图：移动端为相册式流式缩略图，桌面端为支持右键菜单与
/// 拖拽框选的网格。
class WorkspaceGridView extends StatelessWidget {
  const WorkspaceGridView({
    super.key,
    required this.items,
    required this.selectedPath,
    required this.selectedPaths,
    required this.multiSelecting,
    required this.desktop,
    required this.thumbnailSize,
    required this.subtitleBuilder,
    required this.thumbnailLoader,
    required this.thumbnailCacheNamespace,
    required this.onOpen,
    required this.onMore,
    required this.onSelect,
    required this.onToggle,
    this.onLongPress,
    required this.onMarqueeSelectionChanged,
    required this.canUpload,
    required this.canDelete,
    required this.canDownload,
    required this.canMove,
    required this.onDownload,
    required this.onMove,
    required this.onRename,
    required this.renamingTarget,
    required this.onRenameSubmit,
    required this.onRenameCancel,
    required this.onDelete,
    required this.onCreateLink,
  });

  final List<FileItem> items;
  final String? selectedPath;
  final Set<String> selectedPaths;
  final bool multiSelecting;
  final bool desktop;
  final ThumbnailSize thumbnailSize;
  final String Function(FileItem) subtitleBuilder;
  final Future<List<int>> Function(FileItem item) thumbnailLoader;
  final String thumbnailCacheNamespace;
  final ValueChanged<FileItem> onOpen;
  final ValueChanged<FileItem> onMore;
  final ValueChanged<FileItem> onSelect;
  final ValueChanged<FileItem> onToggle;
  final ValueChanged<FileItem>? onLongPress;
  final ValueChanged<Set<String>> onMarqueeSelectionChanged;
  final bool canUpload;
  final bool canDelete;
  final bool canDownload;
  final bool canMove;
  final ValueChanged<FileItem> onDownload;
  final ValueChanged<FileItem> onMove;
  final ValueChanged<FileItem> onRename;
  final ({String path, bool isAlias})? renamingTarget;
  final Future<bool> Function(FileItem item, String name) onRenameSubmit;
  final VoidCallback onRenameCancel;
  final ValueChanged<FileItem> onDelete;
  final ValueChanged<FileItem> onCreateLink;

  @override
  Widget build(BuildContext context) {
    if (!desktop) {
      return MobileUniformGrid(
        items: items,
        selectedPath: selectedPath,
        selectedPaths: selectedPaths,
        multiSelecting: multiSelecting,
        subtitleBuilder: subtitleBuilder,
        thumbnailLoader: thumbnailLoader,
        thumbnailCacheNamespace: thumbnailCacheNamespace,
        onOpen: onOpen,
        onMore: onMore,
        onSelect: onSelect,
        onToggle: onToggle,
        onLongPress: onLongPress,
        bottomPadding: canUpload ? 80 : 12,
      );
    }
    return DesktopMarqueeSelection(
      enabled: desktop && defaultTargetPlatform == TargetPlatform.macOS,
      items: items,
      selectedPaths: selectedPaths,
      onSelectionChanged: onMarqueeSelectionChanged,
      childBuilder: (context, itemKeys, marqueeSelecting, onItemPointerDown) =>
          GridView.builder(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: thumbnailSize.maxCrossAxisExtent,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: thumbnailSize.childAspectRatio,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          final selected = selectedPaths.isNotEmpty
              ? !item.isAlias && selectedPaths.contains(item.path)
              : item.path == selectedPath;

          return Listener(
            onPointerDown: (event) => onItemPointerDown(event.pointer),
            child: Material(
              key: itemKeys[index],
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              child: GestureDetector(
                onSecondaryTapDown: (details) => showDesktopItemMenu(
                  context: context,
                  position: details.globalPosition,
                  item: item,
                  canDownload: canDownload && !item.isAlias,
                  canRename: canUpload || canDelete,
                  canMove: canMove && !item.isAlias,
                  canDelete: canDelete && !item.isAlias,
                  onOpen: () => onOpen(item),
                  onPreview: () => onOpen(item),
                  onDownload: () => onDownload(item),
                  onMove: () => onMove(item),
                  onRename: () => onRename(item),
                  onDelete: () => onDelete(item),
                  onCreateLink: canUpload && item.isDirectory && !item.isAlias
                      ? () => onCreateLink(item)
                      : null,
                  onDeleteLink: item.isAlias ? () => onDelete(item) : null,
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => onSelect(item),
                  onDoubleTap: () => onOpen(item),
                  child: Stack(
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: selected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .outlineVariant),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Expanded(
                                child: FileTypeThumbnail(
                                    item: item,
                                    height: double.infinity,
                                    loader: thumbnailLoader,
                                    cacheNamespace: thumbnailCacheNamespace)),
                            const SizedBox(height: 8),
                            if (isRenamingTarget(renamingTarget, item))
                              InlineRenameField(
                                item: item,
                                onSubmit: onRenameSubmit,
                                onCancel: onRenameCancel,
                              )
                            else
                              Text(item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface)),
                          ],
                        ),
                      ),
                      if (multiSelecting)
                        Positioned(
                          top: 4,
                          left: 4,
                          child: HoverCheckbox(
                            value: selected,
                            onChanged: () => onToggle(item),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
