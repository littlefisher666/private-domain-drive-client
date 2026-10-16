import 'package:flutter/material.dart';

import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';
import 'gallery_page_cloud_badge.dart';
import 'gallery_page_thumbnail_view.dart';

/// 网格中的单个照片/视频单元：缩略图 + 云朵角标 + 视频角标 + 选择态。
class GalleryPagePhotoCell extends StatefulWidget {
  const GalleryPagePhotoCell({
    super.key,
    required this.controller,
    required this.entry,
    required this.cellKey,
    required this.desktop,
    required this.onTap,
    this.onLongPress,
  });

  final GalleryController controller;
  final PhotoEntry entry;
  final GlobalKey cellKey;
  final bool desktop;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<GalleryPagePhotoCell> createState() => _GalleryPagePhotoCellState();
}

class _GalleryPagePhotoCellState extends State<GalleryPagePhotoCell> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return KeyedSubtree(
      key: widget.cellKey,
      child: MouseRegion(
        onEnter:
            widget.desktop ? (_) => setState(() => _hovering = true) : null,
        onExit:
            widget.desktop ? (_) => setState(() => _hovering = false) : null,
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.desktop ? 6 : 2),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: GalleryPageThumbnailView(
                      controller: widget.controller, entry: widget.entry),
                ),
                // 云朵角标：有角标 = 原图未缓存本机。
                ValueListenableBuilder<Set<String>>(
                  valueListenable: widget.controller.cachedKeysListenable,
                  builder: (context, cached, _) {
                    if (cached.contains(widget.entry.key)) {
                      return const SizedBox.shrink();
                    }
                    return Positioned(
                      left: 6,
                      bottom: 6,
                      child: GalleryPageCloudBadge(),
                    );
                  },
                ),
                if (widget.entry.mediaType == PhotoMediaType.video)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Icon(
                        Icons.videocam,
                        size: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ValueListenableBuilder<Set<String>>(
                  valueListenable: widget.controller.selectionListenable,
                  builder: (context, selected, _) {
                    final isSelected = selected.contains(widget.entry.key);
                    final selecting = selected.isNotEmpty;
                    if (!isSelected &&
                        !selecting &&
                        !(_hovering && widget.desktop)) {
                      return const SizedBox.shrink();
                    }
                    return Positioned(
                      top: 6,
                      left: 6,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isSelected
                              ? scheme.primary
                              : Colors.black.withValues(alpha: 0.35),
                          border: isSelected
                              ? null
                              : Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: isSelected
                            ? const Icon(Icons.check,
                                size: 14, color: Colors.white)
                            : null,
                      ),
                    );
                  },
                ),
                ValueListenableBuilder<Set<String>>(
                  valueListenable: widget.controller.selectionListenable,
                  builder: (context, selected, _) {
                    return IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          border: selected.contains(widget.entry.key)
                              ? Border.all(
                                  color: scheme.primary,
                                  width: 2.5,
                                )
                              : null,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
