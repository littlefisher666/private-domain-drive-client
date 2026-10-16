import 'package:flutter/material.dart';

import '../../domain/delete_models.dart';

/// 删除进行中的进度横幅。
class DeleteProgressBanner extends StatelessWidget {
  const DeleteProgressBanner({super.key, required this.progress});

  final DeleteProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              progress.total == 0
                  ? '正在统计待删除对象…'
                  : '正在移入回收站 ${progress.processed}/${progress.total} 个对象…',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
