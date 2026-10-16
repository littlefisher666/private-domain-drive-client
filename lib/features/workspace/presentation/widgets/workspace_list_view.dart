import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../app/theme/cupertino_desktop.dart';
import '../../../../core/utils/file_size_formatter.dart';
import '../../../../shared/widgets/file_icon.dart';
import '../../domain/file_item.dart';
import 'desktop_item_menu.dart';
import 'desktop_marquee_selection.dart';
import 'hover_checkbox.dart';
import 'inline_rename_field.dart';

/// 工作区列表视图：移动端为紧凑卡片列表，桌面端为支持右键菜单与
/// 拖拽框选的行列表。
class WorkspaceListView extends StatelessWidget {
  const WorkspaceListView({
    required this.items,
    required this.desktop,
    required this.selectedPath,
    required this.selectedPaths,
    required this.multiSelecting,
    required this.subtitleBuilder,
    required this.metaTimeBuilder,
    required this.canUpload,
    required this.canDelete,
    required this.canDownload,
    required this.canMove,
    required this.onOpen,
    required this.onMore,
    required this.onSelect,
    required this.onToggle,
    this.onLongPress,
    required this.onMarqueeSelectionChanged,
    required this.onPreview,
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
  final bool desktop;
  final String? selectedPath;
  final Set<String> selectedPaths;
  final bool multiSelecting;
  final String Function(FileItem) subtitleBuilder;
  final String Function(FileItem) metaTimeBuilder;
  final bool canUpload;
  final bool canDelete;
  final bool canDownload;
  final bool canMove;
  final ValueChanged<FileItem> onOpen;
  final ValueChanged<FileItem> onMore;
  final ValueChanged<FileItem> onSelect;
  final ValueChanged<FileItem> onToggle;
  final ValueChanged<FileItem>? onLongPress;
  final ValueChanged<Set<String>> onMarqueeSelectionChanged;
  final ValueChanged<FileItem> onPreview;
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
      return Card(
        clipBehavior: Clip.antiAlias,
        child: ListView.separated(
          padding: EdgeInsets.only(bottom: canUpload ? 80 : 0),
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = items[index];
            return ListTile(
              dense: true,
              visualDensity: const VisualDensity(vertical: -2),
              contentPadding: const EdgeInsets.only(left: 12, right: 4),
              horizontalTitleGap: 10,
              minLeadingWidth: 28,
              minVerticalPadding: 5,
              leading: multiSelecting && !item.isAlias
                  ? SizedBox(
                      width: 28,
                      height: 28,
                      child: Checkbox(
                        value: selectedPaths.contains(item.path),
                        visualDensity: VisualDensity.compact,
                        onChanged: (_) => onToggle(item),
                      ),
                    )
                  : FileTypeIcon(item: item, size: 24),
              title: isRenamingTarget(renamingTarget, item)
                  ? InlineRenameField(
                      item: item,
                      onSubmit: onRenameSubmit,
                      onCancel: onRenameCancel,
                    )
                  : Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
              subtitle: Text(
                subtitleBuilder(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              onTap: () {
                onSelect(item);
                if (!multiSelecting) onOpen(item);
              },
              onLongPress: () => (onLongPress ?? onToggle)(item),
              trailing: IconButton(
                tooltip: '更多',
                visualDensity: VisualDensity.compact,
                constraints:
                    const BoxConstraints.tightFor(width: 40, height: 40),
                onPressed: () => onMore(item),
                icon: const Icon(Icons.more_vert, size: 20),
              ),
            );
          },
        ),
      );
    }

    return DesktopMarqueeSelection(
      enabled: desktop && defaultTargetPlatform == TargetPlatform.macOS,
      items: items,
      selectedPaths: selectedPaths,
      onSelectionChanged: onMarqueeSelectionChanged,
      childBuilder: (context, itemKeys, marqueeSelecting, onItemPointerDown) =>
          ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(
          height: 1,
          color: Color(0x1F3C3C43),
        ),
        itemBuilder: (context, index) {
          final item = items[index];
          // 多选集合不含链接条目（与真实条目可能共用路径），避免误高亮。
          final selected = selectedPaths.isNotEmpty
              ? !item.isAlias && selectedPaths.contains(item.path)
              : item.path == selectedPath;
          return Listener(
            onPointerDown: (event) => onItemPointerDown(event.pointer),
            child: Material(
              key: itemKeys[index],
              color: selected
                  ? CupertinoDesktopTokens.blue.withValues(alpha: 0.12)
                  : Colors.transparent,
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
                  onPreview: () => onPreview(item),
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
                  onTap: () => onSelect(item),
                  onDoubleTap:
                      selectedPaths.isNotEmpty ? null : () => onOpen(item),
                  hoverColor:
                      CupertinoDesktopTokens.blue.withValues(alpha: 0.04),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 11),
                    child: Row(
                      children: <Widget>[
                        if (multiSelecting) ...<Widget>[
                          HoverCheckbox(
                            value: selected,
                            onChanged: () => onToggle(item),
                          ),
                          const SizedBox(width: 6),
                        ],
                        FileTypeBadge(item: item),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              if (isRenamingTarget(renamingTarget, item))
                                InlineRenameField(
                                  item: item,
                                  onSubmit: onRenameSubmit,
                                  onCancel: onRenameCancel,
                                )
                              else
                                Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color:
                                        Theme.of(context).colorScheme.onSurface,
                                  ),
                                ),
                              const SizedBox(height: 2),
                              Text(
                                item.isDirectory
                                    ? item.itemCount == null
                                        ? item.typeLabel
                                        : '${item.itemCount} 项'
                                    : '${item.typeLabel} · ${FileSizeFormatter.format(item.size ?? 0)}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          metaTimeBuilder(item),
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
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
