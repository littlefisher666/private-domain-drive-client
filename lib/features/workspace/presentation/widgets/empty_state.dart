import 'package:flutter/material.dart';

/// 目录为空时的占位视图。
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.canUpload, this.onAction});

  final bool canUpload;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant,
          style: BorderStyle.solid,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '当前目录为空',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            canUpload ? '可以新建文件夹或上传文件。' : '当前目录暂无内容。',
            style: TextStyle(
              fontSize: 13,
              height: 1.55,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (canUpload && onAction != null) ...<Widget>[
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: const Text('上传或新建')),
          ],
        ],
      ),
    );
  }
}
