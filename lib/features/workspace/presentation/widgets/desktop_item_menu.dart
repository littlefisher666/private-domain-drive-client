import 'package:flutter/material.dart';

import '../../domain/file_item.dart';

/// 桌面端右键菜单动作。
enum DesktopItemAction {
  openOrPreview,
  download,
  move,
  rename,
  delete,
  createLink,
  deleteLink,
}

/// 展示桌面端条目右键菜单并分发所选动作。
Future<void> showDesktopItemMenu({
  required BuildContext context,
  required Offset position,
  required FileItem item,
  required bool canDownload,
  required bool canRename,
  required bool canMove,
  required bool canDelete,
  required VoidCallback onOpen,
  required VoidCallback onPreview,
  required VoidCallback onDownload,
  required VoidCallback onMove,
  required VoidCallback onRename,
  required VoidCallback onDelete,
  VoidCallback? onCreateLink,
  VoidCallback? onDeleteLink,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final action = await showMenu<DesktopItemAction>(
    context: context,
    color: Theme.of(context).colorScheme.surface,
    surfaceTintColor: Colors.transparent,
    elevation: 10,
    shadowColor: Theme.of(context).colorScheme.shadow,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    position: RelativeRect.fromRect(
      Rect.fromPoints(position, position),
      Offset.zero & overlay.size,
    ),
    items: <PopupMenuEntry<DesktopItemAction>>[
      _desktopContextMenuItem(
        context: context,
        value: DesktopItemAction.openOrPreview,
        icon: item.isDirectory ? Icons.folder_open_outlined : Icons.open_in_new,
        label: item.isDirectory ? '打开' : '预览 / 打开',
      ),
      if (canDownload)
        _desktopContextMenuItem(
          context: context,
          value: DesktopItemAction.download,
          icon: Icons.download_outlined,
          label: '下载',
        ),
      if (canMove)
        _desktopContextMenuItem(
          context: context,
          value: DesktopItemAction.move,
          icon: Icons.drive_file_move_outlined,
          label: '移动到…',
        ),
      if (canRename)
        _desktopContextMenuItem(
          context: context,
          value: DesktopItemAction.rename,
          icon: Icons.drive_file_rename_outline,
          label: '重命名',
        ),
      if (onCreateLink != null)
        _desktopContextMenuItem(
          context: context,
          value: DesktopItemAction.createLink,
          icon: Icons.add_link,
          label: '创建链接',
        ),
      if (canDelete)
        _desktopContextMenuItem(
          context: context,
          value: DesktopItemAction.delete,
          icon: Icons.delete_outline,
          label: '删除',
          isDestructive: true,
        ),
      if (onDeleteLink != null)
        _desktopContextMenuItem(
          context: context,
          value: DesktopItemAction.deleteLink,
          icon: Icons.link_off,
          label: '删除链接',
          isDestructive: true,
        ),
    ],
  );
  switch (action) {
    case DesktopItemAction.openOrPreview:
      item.isDirectory ? onOpen() : onPreview();
      break;
    case DesktopItemAction.download:
      onDownload();
      break;
    case DesktopItemAction.move:
      onMove();
      break;
    case DesktopItemAction.rename:
      onRename();
      break;
    case DesktopItemAction.delete:
      onDelete();
      break;
    case DesktopItemAction.createLink:
      onCreateLink?.call();
      break;
    case DesktopItemAction.deleteLink:
      onDeleteLink?.call();
      break;
    case null:
      break;
  }
}

PopupMenuItem<DesktopItemAction> _desktopContextMenuItem({
  required BuildContext context,
  required DesktopItemAction value,
  required IconData icon,
  required String label,
  bool isDestructive = false,
}) {
  final scheme = Theme.of(context).colorScheme;
  final color = isDestructive ? scheme.error : scheme.onSurface;
  return PopupMenuItem<DesktopItemAction>(
    value: value,
    height: 40,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: <Widget>[
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w500, color: color),
        ),
      ],
    ),
  );
}
