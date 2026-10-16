import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';

/// 查看器图片区：已缓存读本地文件秒开；未缓存加载降级预览并触发
/// 后台下载，下载完成（缓存状态变化）后无缝替换为原图。
/// 切换时使用与预览页一致的推移动画。
class ViewerImage extends StatefulWidget {
  const ViewerImage({
    super.key,
    required this.gallery,
    required this.entry,
    this.enterOffset = const Offset(1, 0),
  });

  final GalleryController gallery;
  final PhotoEntry entry;

  /// 新图片进入屏幕时的起始偏移（相对自身尺寸）。
  final Offset enterOffset;

  @override
  State<ViewerImage> createState() => _ViewerImageState();
}

class _ViewerImageState extends State<ViewerImage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _transition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );

  int _seq = 0;
  bool _downloadKicked = false;
  bool _fileLoadFailed = false;

  /// 当前显示内容是否已是原图文件（区别于缩略图/预览降级内容）。
  bool _displayingOriginal = false;

  Uint8List? _displayedBytes;
  String? _displayedKey;
  Uint8List? _outgoingBytes;
  Uint8List? _incomingBytes;
  String? _incomingKey;
  Offset _exitOffset = Offset.zero;

  GalleryController get _gallery => widget.gallery;

  @override
  void initState() {
    super.initState();
    _transition.addStatusListener(_handleTransitionStatus);
    _loadFor(widget.entry, animate: false);
  }

  @override
  void didUpdateWidget(covariant ViewerImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final keyChanged = oldWidget.entry.key != widget.entry.key;
    if (keyChanged) {
      _downloadKicked = false;
      _fileLoadFailed = false;
      _displayingOriginal = false;
      _loadFor(widget.entry);
      return;
    }
    // 原图下载完成后无缝替换当前降级内容（缩略图/预览）。
    if (!_displayingOriginal &&
        !_fileLoadFailed &&
        _gallery.isCached(widget.entry.key)) {
      _upgradeToOriginal(widget.entry);
    }
  }

  @override
  void dispose() {
    _transition.dispose();
    super.dispose();
  }

  void _handleTransitionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() {
      _displayedBytes = _incomingBytes;
      _displayedKey = _incomingKey;
      _outgoingBytes = null;
      _incomingBytes = null;
      _incomingKey = null;
    });
  }

  Future<void> _loadFor(PhotoEntry entry, {bool animate = true}) async {
    final seq = ++_seq;
    if (_gallery.isCached(entry.key)) {
      try {
        final file = await _gallery.resolveOriginalFile(entry);
        final bytes = file == null ? null : await file.readAsBytes();
        if (!mounted || seq != _seq) return;
        if (bytes != null) {
          _displayingOriginal = true;
          _applyBytes(entry.key, bytes, animate: animate);
          return;
        }
        _fileLoadFailed = true;
      } catch (_) {
        if (!mounted || seq != _seq) return;
        _fileLoadFailed = true;
      }
      await _loadDegraded(entry, seq, animate: animate);
      return;
    }

    // 未缓存原图：先秒上网格缩略图（通常已在本地缓存），随后后台
    // 下载原图；高清预览到达后无缝替换缩略图。
    final thumb = await _gallery.loadGridThumbnail(entry);
    if (!mounted || seq != _seq) return;
    if (thumb != null && thumb.isNotEmpty) {
      _applyBytes(entry.key, Uint8List.fromList(thumb), animate: animate);
    }
    _kickDownload(entry);
    final preview = await _gallery.loadDegradedPreview(entry);
    if (!mounted || seq != _seq) return;
    if (preview != null &&
        preview.isNotEmpty &&
        !_gallery.isCached(entry.key)) {
      _applyBytes(entry.key, Uint8List.fromList(preview), animate: false);
    }
  }

  /// 原图下载完成后的原地升级：读取本地缓存原图替换降级内容，
  /// 不做滑动动画。
  Future<void> _upgradeToOriginal(PhotoEntry entry) async {
    final seq = ++_seq;
    try {
      final file = await _gallery.resolveOriginalFile(entry);
      final bytes = file == null ? null : await file.readAsBytes();
      if (!mounted || seq != _seq) return;
      if (bytes != null) {
        _displayingOriginal = true;
        _applyBytes(entry.key, bytes, animate: false);
      } else {
        _fileLoadFailed = true;
      }
    } catch (_) {
      if (!mounted || seq != _seq) return;
      _fileLoadFailed = true;
    }
  }

  Future<void> _loadDegraded(
    PhotoEntry entry,
    int seq, {
    required bool animate,
  }) async {
    final bytes = await _gallery.loadDegradedPreview(entry);
    if (!mounted || seq != _seq) return;
    if (bytes != null && bytes.isNotEmpty) {
      _applyBytes(entry.key, Uint8List.fromList(bytes), animate: animate);
    }
  }

  void _applyBytes(String key, Uint8List bytes, {required bool animate}) {
    if (_incomingKey == key) {
      setState(() => _incomingBytes = bytes);
      return;
    }
    if (_displayedKey == key) {
      setState(() => _displayedBytes = bytes);
      return;
    }
    if (_displayedBytes == null || !animate) {
      setState(() {
        _displayedBytes = bytes;
        _displayedKey = key;
      });
      return;
    }
    setState(() {
      if (_incomingBytes != null) {
        _displayedBytes = _incomingBytes;
        _displayedKey = _incomingKey;
      }
      _outgoingBytes = _displayedBytes;
      _incomingBytes = bytes;
      _incomingKey = key;
      _exitOffset = -widget.enterOffset;
    });
    _transition.forward(from: 0);
  }

  void _kickDownload(PhotoEntry entry) {
    if (_downloadKicked) return;
    _downloadKicked = true;
    widget.gallery.downloadOriginal(entry);
  }

  @override
  Widget build(BuildContext context) {
    if (_displayedBytes == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    final children = <Widget>[_image(_displayedBytes!)];
    if (_incomingBytes != null && _outgoingBytes != null) {
      children
        ..clear()
        ..add(
          SlideTransition(
            position: Tween<Offset>(
              begin: Offset.zero,
              end: _exitOffset,
            ).animate(CurvedAnimation(
              parent: _transition,
              curve: Curves.easeInCubic,
            )),
            child: _image(_outgoingBytes!),
          ),
        )
        ..add(
          SlideTransition(
            position: Tween<Offset>(
              begin: widget.enterOffset,
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: _transition,
              curve: Curves.easeOutCubic,
            )),
            child: _image(_incomingBytes!),
          ),
        );
    }
    return Stack(
      fit: StackFit.expand,
      children: children,
    );
  }

  Widget _image(Uint8List bytes) {
    return Image.memory(
      bytes,
      fit: BoxFit.contain,
      gaplessPlayback: true,
    );
  }
}
