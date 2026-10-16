import 'package:flutter/material.dart';

import '../../../../shared/file_size_formatter_lite.dart';
import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';
import 'gallery_viewer_download_button.dart';
import 'gallery_viewer_mobile_detail_sheet.dart';
import 'gallery_viewer_shared_utils.dart';
import 'gallery_viewer_video_player_view.dart';
import 'gallery_viewer_image.dart';

/// 移动端查看器：四方向滑动推移切换条目，上滑呼出详情面板。
class MobileViewer extends StatefulWidget {
  const MobileViewer({
    super.key,
    required this.gallery,
    required this.entry,
    required this.sequence,
    required this.onBack,
    required this.onSwipe,
    required this.onDelete,
    required this.onShare,
  });

  final GalleryController gallery;
  final PhotoEntry entry;
  final List<PhotoEntry> sequence;
  final VoidCallback onBack;
  final void Function(double velocity, bool vertical) onSwipe;
  final VoidCallback onDelete;
  final VoidCallback onShare;

  @override
  State<MobileViewer> createState() => _MobileViewerState();
}

class _MobileViewerState extends State<MobileViewer> {
  Offset _enterOffset = const Offset(1, 0);
  bool _detailVisible = false;

  void _handleSwipe(double velocity, bool vertical) {
    if (vertical) {
      setState(() => _detailVisible = velocity < 0);
      return;
    }
    final forward = velocity < 0;
    setState(() {
      _enterOffset = forward ? const Offset(1, 0) : const Offset(-1, 0);
    });
    widget.onSwipe(velocity, vertical);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final isVideo = entry.mediaType == PhotoMediaType.video;
    final dateText = formatTakenAt(entry.takenAt);
    final metaText = <String>[
      if (entry.width != null && entry.height != null)
        '${entry.width} × ${entry.height}',
      FileSizeFormatterLite.format(entry.size),
    ].join(' · ');
    final index = widget.sequence.indexWhere((e) => e.key == entry.key);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _detailVisible
                  ? () => setState(() => _detailVisible = false)
                  : null,
              onHorizontalDragEnd: (details) =>
                  _handleSwipe(details.velocity.pixelsPerSecond.dx, false),
              onVerticalDragEnd: (details) =>
                  _handleSwipe(details.velocity.pixelsPerSecond.dy, true),
              child: isVideo
                  ? VideoPlayerView(gallery: widget.gallery, entry: entry)
                  : ViewerImage(
                      gallery: widget.gallery,
                      entry: entry,
                      enterOffset: _enterOffset,
                    ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Colors.black54, Colors.transparent],
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: widget.onBack,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            dateText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            metaText,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 40, 16, 18),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Colors.transparent, Colors.black54],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    DownloadButton(gallery: widget.gallery, entry: entry),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: <Widget>[
                        TextButton.icon(
                          onPressed: widget.onShare,
                          icon: const Icon(Icons.share_outlined,
                              color: Colors.white, size: 20),
                          label: const Text('分享',
                              style: TextStyle(color: Colors.white)),
                        ),
                        TextButton.icon(
                          onPressed: widget.onDelete,
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.white, size: 20),
                          label: const Text('删除',
                              style: TextStyle(color: Colors.white)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (index >= 0 && widget.sequence.length > 1)
              Positioned(
                bottom: 136,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${index + 1} / ${widget.sequence.length}',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
              ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              bottom: _detailVisible ? 0 : -320,
              left: 0,
              right: 0,
              child: MobileDetailSheet(
                gallery: widget.gallery,
                entry: entry,
                onClose: () => setState(() => _detailVisible = false),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
