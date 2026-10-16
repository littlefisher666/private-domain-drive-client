import 'package:flutter/material.dart';

import '../../../../shared/file_size_formatter_lite.dart';
import '../../../transfer/domain/transfer_task.dart';
import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';
import 'gallery_viewer_overlay_action.dart';
import 'gallery_viewer_shared_utils.dart';

/// 底部原图下载操作：展示下载状态（下载中 / 重试）与原图大小。
class DownloadOverlayAction extends StatelessWidget {
  const DownloadOverlayAction({super.key, required this.gallery, required this.entry});

  final GalleryController gallery;
  final PhotoEntry entry;

  @override
  Widget build(BuildContext context) {
    final cached = gallery.isCached(entry.key);
    if (cached) {
      return OverlayAction(
        icon: Icons.check_circle_outline,
        label: '已缓存',
        onTap: _noop,
      );
    }
    final task = downloadTaskFor(gallery.appTasks, entry);
    final active = task != null &&
        (task.status == TransferTaskStatus.pending ||
            task.status == TransferTaskStatus.running);
    final failed = task?.status == TransferTaskStatus.failed;
    return OverlayAction(
      icon: failed ? Icons.refresh : Icons.download_outlined,
      label: active
          ? '下载中…'
          : failed
              ? '重试下载'
              : '下载原图${entry.size > 0 ? ' · ${FileSizeFormatterLite.format(entry.size)}' : ''}',
      onTap: active ? _noop : () => gallery.downloadOriginal(entry),
    );
  }

  static void _noop() {}
}
