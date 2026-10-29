import 'package:flutter/material.dart';

/// 回收站批量操作条：恢复、立即删除、全选与退出多选。
class RecycleBinBatchBar extends StatelessWidget {
  const RecycleBinBatchBar({
    super.key,
    required this.selectedCount,
    required this.itemCount,
    required this.busy,
    required this.onSelectAll,
    required this.onClearSelection,
    required this.onRestore,
    required this.onPurge,
  });

  final int selectedCount;
  final int itemCount;
  final bool busy;
  final VoidCallback onSelectAll;
  final VoidCallback onClearSelection;
  final VoidCallback onRestore;
  final VoidCallback onPurge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allSelected = selectedCount > 0 && selectedCount == itemCount;
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
            value: allSelected
                ? true
                : selectedCount > 0
                    ? null
                    : false,
            tristate: true,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (busy || itemCount == 0) ? null : (_) => onSelectAll(),
          ),
          Text(
            selectedCount > 0 ? '已选 $selectedCount 项' : '共 $itemCount 项',
            style:
                TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurface),
          ),
          FilledButton.icon(
            onPressed: (!busy && selectedCount > 0) ? onRestore : null,
            style: compactButtonStyle,
            icon: const Icon(Icons.restore_outlined),
            label: const Text('恢复'),
          ),
          TextButton.icon(
            onPressed: (!busy && selectedCount > 0) ? onPurge : null,
            style: compactButtonStyle.copyWith(
              foregroundColor: WidgetStatePropertyAll<Color>(scheme.error),
            ),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('立即删除'),
          ),
          if (selectedCount > 0)
            TextButton.icon(
              onPressed: busy ? null : onClearSelection,
              style: compactButtonStyle,
              icon: const Icon(Icons.close),
              label: const Text('退出多选'),
            ),
        ],
      ),
    );
  }
}
