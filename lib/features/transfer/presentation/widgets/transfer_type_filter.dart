import 'package:flutter/material.dart';

import '../../domain/transfer_task.dart';
import '../../domain/transfer_type_counts.dart';

class TransferTypeFilter extends StatelessWidget {
  const TransferTypeFilter({
    super.key,
    required this.selectedType,
    required this.counts,
    required this.onSelected,
    this.dense = false,
  });

  final TransferTaskType? selectedType;

  /// 计数基于保留范围内全部历史记录与内存中未结束任务之和，
  /// 不因历史分页而缺失。
  final TransferTypeCounts counts;
  final ValueChanged<TransferTaskType?> onSelected;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (!dense) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          border: Border(
            bottom:
                BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          ),
        ),
        child: Wrap(
          spacing: 8,
          children: <Widget>[
            ChoiceChip(
              label: Text('全部 ${counts.total}'),
              selected: selectedType == null,
              onSelected: (_) => onSelected(null),
            ),
            ChoiceChip(
              label: Text('上传 ${counts.upload}'),
              selected: selectedType == TransferTaskType.upload,
              onSelected: (_) => onSelected(TransferTaskType.upload),
            ),
            ChoiceChip(
              label: Text('下载 ${counts.download}'),
              selected: selectedType == TransferTaskType.download,
              onSelected: (_) => onSelected(TransferTaskType.download),
            ),
          ],
        ),
      );
    }
    // 移动端用无底色文字 Tab，比 ChoiceChip 明显更矮。
    final theme = Theme.of(context);
    final unselectedStyle = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final selectedStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w700,
    );
    Widget tab(String label, TransferTaskType? type) {
      final selected = selectedType == type;
      return InkWell(
        onTap: () => onSelected(type),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Text(label, style: selected ? selectedStyle : unselectedStyle),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: <Widget>[
          tab('全部 ${counts.total}', null),
          tab('上传 ${counts.upload}', TransferTaskType.upload),
          tab('下载 ${counts.download}', TransferTaskType.download),
        ],
      ),
    );
  }
}
