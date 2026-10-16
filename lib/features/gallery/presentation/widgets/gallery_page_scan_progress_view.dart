import 'package:flutter/material.dart';

import '../../application/gallery_controller.dart';

/// 相册扫描进度视图：整体/分页进度 + 提示文案。
class GalleryPageScanProgressView extends StatelessWidget {
  const GalleryPageScanProgressView({super.key, required this.controller});

  final GalleryController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ValueListenableBuilder<(int, int)?>(
        valueListenable: controller.scanProgressListenable,
        builder: (context, progress, _) {
          final total = progress?.$2 ?? 0;
          final processed = progress?.$1 ?? 0;
          final ratio = total > 0 ? processed / total : 0.0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 48,
                height: 48,
                child: total > 0
                    ? CircularProgressIndicator(value: ratio)
                    : const CircularProgressIndicator(),
              ),
              const SizedBox(height: 16),
              Text(
                '正在建立照片索引…',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                total > 0 ? '已处理 $processed / $total 张' : '正在扫描网盘中的照片和视频',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
