import 'package:flutter/material.dart';

class TransferSelectionActions extends StatelessWidget {
  const TransferSelectionActions({
    super.key,
    required this.selectedCount,
    required this.allVisibleSelected,
    required this.retryCount,
    required this.cancelCount,
    required this.onToggleAll,
    required this.onRetry,
    required this.onCancel,
    required this.onClear,
  });

  final int selectedCount;
  final bool allVisibleSelected;
  final int retryCount;
  final int cancelCount;
  final VoidCallback onToggleAll;
  final VoidCallback onRetry;
  final VoidCallback onCancel;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          TextButton.icon(
            onPressed: onToggleAll,
            icon: Icon(
              allVisibleSelected
                  ? Icons.check_box_outlined
                  : Icons.select_all_outlined,
            ),
            label: Text(allVisibleSelected ? '取消全选' : '全选当前列表'),
          ),
          if (selectedCount > 0) ...<Widget>[
            Text('已选 $selectedCount 项'),
            OutlinedButton(
              onPressed: retryCount == 0 ? null : onRetry,
              child: Text('批量重试${retryCount == 0 ? '' : ' ($retryCount)'}'),
            ),
            OutlinedButton(
              onPressed: cancelCount == 0 ? null : onCancel,
              child: Text('批量取消${cancelCount == 0 ? '' : ' ($cancelCount)'}'),
            ),
            TextButton(onPressed: onClear, child: const Text('取消选择')),
          ],
        ],
      ),
    );
  }
}
