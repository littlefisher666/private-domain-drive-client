import 'package:flutter/material.dart';

import '../../../../shared/widgets/app_feedback.dart';
import '../../application/gallery_controller.dart';

/// 移动端顶部应用栏：多选时显示已选数量与全选操作。
class GalleryPageMobileAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const GalleryPageMobileAppBar({super.key, required this.controller});

  final GalleryController controller;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: controller.selectionListenable,
      builder: (context, selected, _) {
        final selecting = selected.isNotEmpty;
        return AppBar(
          leading: selecting
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: controller.clearSelection,
                )
              : null,
          title: Text(selecting ? '已选择 ${selected.length} 张' : '相册'),
          actions: <Widget>[
            if (selecting)
              IconButton(
                tooltip: '全选',
                icon: const Icon(Icons.select_all),
                onPressed: controller.selectAll,
              )
            else
              PopupMenuButton<String>(
                tooltip: '更多操作',
                onSelected: (value) {
                  if (value == 'rebuild-index' &&
                      controller.phase != GalleryPhase.scanning) {
                    AppFeedback.showSnack(context, '正在重建照片索引…');
                    controller.rebuildIndex();
                  }
                },
                itemBuilder: (context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                    value: 'rebuild-index',
                    child: Text('重建照片索引'),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}
