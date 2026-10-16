import 'package:flutter/material.dart';

import '../../domain/move_models.dart';

/// 移动进行中的进度横幅。
class MoveProgressBanner extends StatelessWidget {
  const MoveProgressBanner({super.key, required this.progress});

  final MoveProgress progress;

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
              progress.isUndo
                  ? '正在撤销移动，搬回 ${progress.processed}/${progress.total} 个对象…'
                  : '正在移动 ${progress.processed}/${progress.total} 个对象…',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
          ),
          if (progress.isCounting)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Tooltip(
                message: '仍在统计待迁移文件总数',
                child: const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
