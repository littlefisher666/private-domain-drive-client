import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../shared/widgets/app_feedback.dart';
import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';

/// 桌面端快捷键：⌘A 全选、⌘C 复制、⌘V 粘贴上传（界面不展示快捷键说明）。
class GalleryPageDesktopShortcuts extends StatelessWidget {
  const GalleryPageDesktopShortcuts({
    super.key,
    required this.controller,
    required this.child,
  });

  final GalleryController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
            controller.selectAll,
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () {
          _copy(context);
        },
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            controller.pasteUpload,
      },
      child: Focus(
        autofocus: true,
        child: child,
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final selected = controller.selectedKeys
        .map(controller.entryOfKey)
        .whereType<PhotoEntry>()
        .toList();
    if (selected.isEmpty) return;
    final error = await controller.copyToClipboard(selected);
    if (context.mounted) {
      AppFeedback.showSnack(context, error ?? '已复制 ${selected.length} 张原图到剪贴板');
    }
  }
}
