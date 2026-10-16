import 'package:flutter/material.dart';

import '../../../../shared/widgets/app_feedback.dart';
import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';

/// 确认后执行批量删除；非阻塞反馈，删除期间通过防重入避免重复提交。
Future<void> confirmAndDeleteEntries(
  BuildContext context,
  GalleryController controller,
  List<PhotoEntry> entries,
) async {
  if (entries.isEmpty) return;
  if (controller.deleteBusy) {
    AppFeedback.showSnack(context, '正在删除中，请稍候…');
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('删除所选照片'),
      content: Text('将 ${entries.length} 张照片和视频移入回收站？'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  // 立即清空多选，避免删除进行中同一批条目被再次提交。
  controller.clearSelection();
  AppFeedback.showSnack(context, '正在移入回收站 ${entries.length} 项…');
  await controller.deleteEntries(entries);
  if (context.mounted) {
    AppFeedback.showSnack(context, '已移入回收站');
  }
}
