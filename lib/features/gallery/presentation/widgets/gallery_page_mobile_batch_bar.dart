import 'package:flutter/material.dart';

import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';
import 'gallery_page_batch_action.dart';
import 'gallery_page_delete_confirm.dart';

/// 移动端多选后的底部批量操作栏。
class GalleryPageMobileBatchBar extends StatelessWidget {
  const GalleryPageMobileBatchBar({super.key, required this.controller});

  final GalleryController controller;

  @override
  Widget build(BuildContext context) {
    final selected = controller.selectedKeys
        .map(controller.entryOfKey)
        .whereType<PhotoEntry>()
        .toList();
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top:
                BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: <Widget>[
            BatchAction(
              icon: Icons.download_outlined,
              label: '下载原图',
              onTap: () => controller.downloadOriginals(selected),
            ),
            BatchAction(
              icon: Icons.share_outlined,
              label: '分享',
              onTap: () => _share(context, selected),
            ),
            BatchAction(
              icon: Icons.delete_outline,
              label: '删除',
              danger: true,
              onTap: () => _delete(context, selected),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _share(BuildContext context, List<PhotoEntry> selected) async {
    if (selected.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(selected.any((entry) => !controller.isCached(entry.key))
            ? '正在下载原图，完成后自动分享…'
            : '正在准备分享…'),
      ),
    );
    final error = await controller.shareEntries(selected);
    if (error != null) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _delete(BuildContext context, List<PhotoEntry> selected) async {
    await confirmAndDeleteEntries(context, controller, selected);
  }
}
