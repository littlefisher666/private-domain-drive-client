import 'package:flutter/material.dart';

import '../../domain/timeline_group.dart';

/// 时间线分组标题行：分组名 + 条目数 + 折叠指示箭头。
class GalleryPageGroupHeader extends StatelessWidget {
  const GalleryPageGroupHeader({
    super.key,
    required this.group,
    required this.collapsed,
    required this.onToggle,
  });

  final TimelineGroup group;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Text(
              group.label,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${group.entries.length} 张',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            AnimatedRotation(
              turns: collapsed ? -0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(
                Icons.expand_more,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
