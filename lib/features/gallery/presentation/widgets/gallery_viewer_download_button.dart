import 'package:flutter/material.dart';

import '../../../../shared/file_size_formatter_lite.dart';
import '../../../transfer/domain/transfer_task.dart';
import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';
import 'gallery_viewer_shared_utils.dart';

/// 移动端原图下载按钮（主 CTA 样式）。
class DownloadButton extends StatelessWidget {
  const DownloadButton({super.key, required this.gallery, required this.entry});

  final GalleryController gallery;
  final PhotoEntry entry;

  @override
  Widget build(BuildContext context) {
    final cached = gallery.isCached(entry.key);
    final task = downloadTaskFor(gallery.appTasks, entry);
    final active = task != null &&
        (task.status == TransferTaskStatus.pending ||
            task.status == TransferTaskStatus.running);
    final failed = task?.status == TransferTaskStatus.failed;
    final label = cached
        ? '原图已缓存'
        : active
            ? '正在下载原图…'
            : failed
                ? '下载失败，点击重试 · ${FileSizeFormatterLite.format(entry.size)}'
                : '下载原图 · ${FileSizeFormatterLite.format(entry.size)}';
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: cached || active ? null : () => gallery.downloadOriginal(entry),
        style: cached
            ? FilledButton.styleFrom(
                backgroundColor: Colors.white24,
                foregroundColor: Colors.white70,
              )
            : null,
        icon: Icon(cached
            ? Icons.check_circle_outline
            : active
                ? Icons.downloading
                : Icons.download_outlined),
        label: Text(label),
      ),
    );
  }
}
