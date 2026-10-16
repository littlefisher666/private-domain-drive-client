import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';

/// 网格缩略图：按条目 key / 缩略图映射变化自动重载。
class GalleryPageThumbnailView extends StatefulWidget {
  const GalleryPageThumbnailView({
    super.key,
    required this.controller,
    required this.entry,
  });

  final GalleryController controller;
  final PhotoEntry entry;

  @override
  State<GalleryPageThumbnailView> createState() =>
      _GalleryPageThumbnailViewState();
}

class _GalleryPageThumbnailViewState extends State<GalleryPageThumbnailView> {
  late Future<List<int>?> _future;
  String? _fetchedThumbKey;

  @override
  void initState() {
    super.initState();
    _startFetch();
  }

  void _startFetch() {
    _fetchedThumbKey = widget.entry.thumbKey;
    _future = widget.controller.loadGridThumbnail(widget.entry);
  }

  @override
  void didUpdateWidget(covariant GalleryPageThumbnailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // key 或缩略图映射变化都重载：存量缩略图补齐完成后，同一 key 的
    // 条目会从"无映射"变为"有映射"，需要重试加载。
    if (oldWidget.entry.key != widget.entry.key ||
        widget.entry.thumbKey != _fetchedThumbKey) {
      _startFetch();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.entry.mediaType == PhotoMediaType.video;
    return FutureBuilder<List<int>?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null && bytes.isNotEmpty) {
          return Image.memory(
            Uint8List.fromList(bytes),
            fit: BoxFit.cover,
            gaplessPlayback: true,
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        // 无缩略图（含无截帧映射的视频）展示占位图。
        return Center(
          child: Icon(
            isVideo ? Icons.videocam_outlined : Icons.image_outlined,
            size: 32,
            color: Theme.of(context).colorScheme.outline,
          ),
        );
      },
    );
  }
}
