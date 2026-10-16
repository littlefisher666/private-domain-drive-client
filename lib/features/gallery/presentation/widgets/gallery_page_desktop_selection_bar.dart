import 'package:flutter/material.dart';

import '../../../../shared/widgets/app_feedback.dart';
import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';
import 'gallery_page_delete_confirm.dart';

/// 桌面端顶部选择操作条：全选/复制/下载原图/删除/取消。
class GalleryPageDesktopSelectionBar extends StatelessWidget {
  const GalleryPageDesktopSelectionBar({super.key, required this.controller});

  final GalleryController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: controller.selectionListenable,
      builder: (context, selected, _) {
        if (selected.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            border: Border(
              bottom: BorderSide(color: scheme.outlineVariant),
            ),
          ),
          child: Row(
            children: <Widget>[
              Text(
                '已选择 ${selected.length} 张',
                style: theme.textTheme.titleSmall,
              ),
              const Spacer(),
              TextButton(
                onPressed: controller.selectAll,
                child: const Text('全选'),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: controller.clipboardCopiedListenable,
                builder: (context, copied, _) => TextButton(
                  onPressed: () async {
                    final entries = selected
                        .map(controller.entryOfKey)
                        .whereType<PhotoEntry>();
                    final error = await controller.copyToClipboard(entries);
                    if (context.mounted) {
                      AppFeedback.showSnack(
                          context, error ?? '已复制 ${entries.length} 张原图到剪贴板');
                    }
                  },
                  child: Text(copied ? '已复制' : '复制'),
                ),
              ),
              TextButton(
                onPressed: () {
                  controller.downloadOriginals(selected
                      .map(controller.entryOfKey)
                      .whereType<PhotoEntry>());
                },
                child: const Text('下载原图'),
              ),
              TextButton(
                onPressed: () {
                  confirmAndDeleteEntries(
                    context,
                    controller,
                    selected
                        .map(controller.entryOfKey)
                        .whereType<PhotoEntry>()
                        .toList(),
                  );
                },
                style: TextButton.styleFrom(
                  foregroundColor: scheme.error,
                ),
                child: const Text('删除'),
              ),
              TextButton(
                onPressed: controller.clearSelection,
                child: const Text('取消'),
              ),
            ],
          ),
        );
      },
    );
  }
}
