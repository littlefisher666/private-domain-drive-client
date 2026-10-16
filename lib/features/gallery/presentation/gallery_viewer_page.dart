import 'package:flutter/material.dart';

import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../application/gallery_controller.dart';
import '../domain/photo_entry.dart';
import 'gallery_scope.dart';
import 'widgets/gallery_viewer_desktop_viewer.dart';
import 'widgets/gallery_viewer_mobile_viewer.dart';

class GalleryViewerArguments {
  const GalleryViewerArguments({required this.initialKey});

  final String initialKey;
}

/// 大图查看器：已缓存原图秒开；未缓存先降级预览并后台下载原图，
/// 完成后无缝替换。桌面端提供信息栏、滚轮缩放与方向键；
/// 移动端沿用预览页的四方向滑动推移交互（切换范围为当前分组）。
class GalleryViewerPage extends StatefulWidget {
  const GalleryViewerPage({super.key, required this.arguments});

  final GalleryViewerArguments arguments;

  @override
  State<GalleryViewerPage> createState() => _GalleryViewerPageState();
}

class _GalleryViewerPageState extends State<GalleryViewerPage> {
  late String _currentKey;

  @override
  void initState() {
    super.initState();
    _currentKey = widget.arguments.initialKey;
  }

  /// 全库媒体连续浏览序列（按拍摄时间排序，图片与视频混合切换）。
  List<PhotoEntry> _sequenceOf(GalleryController gallery) {
    return gallery.entries.toList(growable: false);
  }

  PhotoEntry? _resolveCurrent(GalleryController gallery) {
    final entry = gallery.entryOfKey(_currentKey);
    if (entry != null) return entry;
    // 当前照片刚被删除时切换到分组内第一张；分组为空则关闭查看器。
    final sequence = _sequenceOf(gallery);
    if (sequence.isEmpty) return null;
    return sequence.first;
  }

  void _goNext(GalleryController gallery, {bool forward = true}) {
    final sequence = _sequenceOf(gallery);
    if (sequence.length < 2) return;
    final index = sequence.indexWhere((entry) => entry.key == _currentKey);
    if (index < 0) return;
    final next = (index + (forward ? 1 : -1)) % sequence.length;
    setState(() => _currentKey = sequence[next].key);
  }

  Future<void> _deleteCurrent(GalleryController gallery) async {
    final entry = gallery.entryOfKey(_currentKey);
    if (entry == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: const Text('将这张照片移入回收站？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    AppFeedback.showSnack(context, '正在移入回收站…');
    try {
      final sequence = _sequenceOf(gallery);
      final deletedIndex =
          sequence.indexWhere((candidate) => candidate.key == entry.key);
      await gallery.deleteEntries(<PhotoEntry>[entry]);
      if (!mounted) return;
      final remaining = _sequenceOf(gallery);
      if (remaining.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _currentKey = remaining[deletedIndex.clamp(0, remaining.length - 1)].key;
      });
    } finally {
      if (mounted) {
        AppFeedback.showSnack(context, '已移入回收站');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final gallery = GalleryScope.of(context);
    final app = AppScope.of(context);
    final entry = _resolveCurrent(gallery);
    if (entry == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const Scaffold(backgroundColor: Colors.black);
    }
    final sequence = _sequenceOf(gallery);

    if (gallery.isDesktop) {
      return DesktopViewer(
        gallery: gallery,
        app: app,
        entry: entry,
        sequence: sequence,
        onBack: () => Navigator.of(context).pop(),
        onNext: () => _goNext(gallery),
        onPrev: () => _goNext(gallery, forward: false),
        onDelete: () => _deleteCurrent(gallery),
      );
    }
    return MobileViewer(
      gallery: gallery,
      entry: entry,
      sequence: sequence,
      onBack: () => Navigator.of(context).pop(),
      onSwipe: (velocity, vertical) =>
          _goNext(gallery, forward: velocity < 0),
      onDelete: () => _deleteCurrent(gallery),
      onShare: () => _shareCurrent(gallery, entry),
    );
  }

  Future<void> _shareCurrent(GalleryController gallery, PhotoEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('正在准备分享…')),
    );
    final error = await gallery.shareEntries(<PhotoEntry>[entry]);
    if (error != null) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }
}
