import 'package:flutter/material.dart';

/// 批量多选操作条：展示已选数量并提供下载/移动/删除入口。
class BatchSelectionBar extends StatelessWidget {
  const BatchSelectionBar({
    super.key,
    required this.selectedCount,
    required this.allSelected,
    required this.itemCount,
    required this.canDownload,
    required this.canMove,
    required this.canDelete,
    required this.onSelectAll,
    this.onDownload,
    this.onMove,
    this.onDelete,
  });

  final int selectedCount;
  final bool allSelected;
  final int itemCount;
  final bool canDownload;
  final bool canMove;
  final bool canDelete;
  final VoidCallback onSelectAll;
  final VoidCallback? onDownload;
  final VoidCallback? onMove;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const compactButtonStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(Size(0, 32)),
      padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Checkbox(
            value: allSelected && itemCount > 0
                ? true
                : selectedCount > 0
                    ? null
                    : false,
            tristate: true,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: itemCount == 0 ? null : (_) => onSelectAll(),
          ),
          Text(
            selectedCount > 0 ? '已选 $selectedCount 项' : '已全部加载，共 $itemCount 项',
            style:
                TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurface),
          ),
          if (selectedCount > 0 && canDownload)
            FilledButton.icon(
              onPressed: onDownload,
              style: compactButtonStyle,
              icon: const Icon(Icons.download_outlined),
              label: const Text('下载'),
            ),
          if (selectedCount > 0 && canMove)
            FilledButton.icon(
              onPressed: onMove,
              style: compactButtonStyle,
              icon: const Icon(Icons.drive_file_move_outlined),
              label: const Text('移动'),
            ),
          if (selectedCount > 0 && canDelete)
            TextButton.icon(
              onPressed: onDelete,
              style: compactButtonStyle.copyWith(
                foregroundColor: WidgetStatePropertyAll<Color>(scheme.error),
              ),
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除'),
            ),
        ],
      ),
    );
  }
}
