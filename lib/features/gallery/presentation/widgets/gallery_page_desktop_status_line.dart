import 'package:flutter/material.dart';

import '../../../../core/utils/file_size_formatter.dart';
import '../../../../shared/widgets/app_feedback.dart';
import '../../application/gallery_controller.dart';

/// 桌面端底部状态行：总条目数、已用空间、未缓存数量与重建索引入口。
class GalleryPageDesktopStatusLine extends StatelessWidget {
  const GalleryPageDesktopStatusLine({super.key, required this.controller});

  final GalleryController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: ValueListenableBuilder<Set<String>>(
        valueListenable: controller.cachedKeysListenable,
        builder: (context, cached, _) {
          final entries = controller.entries;
          final totalBytes =
              entries.fold<int>(0, (sum, entry) => sum + entry.size);
          final uncached = entries.where((e) => !cached.contains(e.key)).length;
          return Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '共 ${entries.length} 张照片和视频 · 已用空间 '
                  '${FileSizeFormatter.format(totalBytes)}'
                  '${uncached > 0 ? ' · 其中 $uncached 张原图未缓存到本机' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(
                onPressed: controller.phase == GalleryPhase.scanning
                    ? null
                    : () {
                        AppFeedback.showSnack(context, '正在重建照片索引…');
                        controller.rebuildIndex();
                      },
                child: const Text('重建索引'),
              ),
            ],
          );
        },
      ),
    );
  }
}
