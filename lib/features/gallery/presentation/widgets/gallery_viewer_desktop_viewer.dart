import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../shared/state/app_services.dart';
import '../../../../shared/widgets/app_feedback.dart';
import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';
import 'gallery_viewer_download_overlay_action.dart';
import 'gallery_viewer_image.dart';
import 'gallery_viewer_info_panel.dart';
import 'gallery_viewer_overlay_action.dart';
import 'gallery_viewer_video_player_view.dart';

/// 桌面端查看器：左侧大图（滚轮缩放、方向键切换）+ 右侧信息栏，
/// 鼠标静止时自动隐藏顶部/底部操作栏。
class DesktopViewer extends StatefulWidget {
  const DesktopViewer({
    super.key,
    required this.gallery,
    required this.app,
    required this.entry,
    required this.sequence,
    required this.onBack,
    required this.onNext,
    required this.onPrev,
    required this.onDelete,
  });

  final GalleryController gallery;
  final AppServices app;
  final PhotoEntry entry;
  final List<PhotoEntry> sequence;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final VoidCallback onDelete;

  @override
  State<DesktopViewer> createState() => _DesktopViewerState();
}

class _DesktopViewerState extends State<DesktopViewer> {
  bool _overlaysVisible = true;
  bool _pointerInOverlay = false;
  bool _copied = false;
  Timer? _hideTimer;
  Timer? _copiedTimer;
  final TransformationController _transform = TransformationController();

  void _markCopied() {
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _copyCurrent() async {
    final error =
        await widget.gallery.copyToClipboard(<PhotoEntry>[widget.entry]);
    if (!mounted) return;
    AppFeedback.showSnack(context, error ?? '已复制原图到剪贴板');
    if (error == null) _markCopied();
  }

  void _wake() {
    _hideTimer?.cancel();
    if (!_overlaysVisible) setState(() => _overlaysVisible = true);
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && !_pointerInOverlay) {
        setState(() => _overlaysVisible = false);
      }
    });
  }

  void _holdOverlay() {
    _pointerInOverlay = true;
    _hideTimer?.cancel();
    if (!_overlaysVisible) setState(() => _overlaysVisible = true);
  }

  void _releaseOverlay() {
    _pointerInOverlay = false;
    _wake();
  }

  void _onScroll(PointerScrollEvent event) {
    final matrix = _transform.value.clone();
    final currentScale = matrix.getMaxScaleOnAxis();
    final factor = event.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15;
    final newScale = (currentScale * factor).clamp(0.5, 10.0);
    final position = event.localPosition;
    matrix
      ..translateByDouble(position.dx, position.dy, 0, 1)
      ..scaleByDouble(newScale / currentScale, newScale / currentScale, 1, 1)
      ..translateByDouble(-position.dx, -position.dy, 0, 1);
    _transform.value = matrix;
  }

  @override
  void didUpdateWidget(covariant DesktopViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.key != widget.entry.key) {
      _transform.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _copiedTimer?.cancel();
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final isVideo = entry.mediaType == PhotoMediaType.video;
    final index =
        widget.sequence.indexWhere((candidate) => candidate.key == entry.key);

    return Scaffold(
      backgroundColor: const Color(0xFF101216),
      body: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.arrowLeft): widget.onPrev,
          const SingleActivator(LogicalKeyboardKey.arrowRight): widget.onNext,
          const SingleActivator(LogicalKeyboardKey.escape): widget.onBack,
          const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () {
            _copyCurrent();
          },
        },
        child: Focus(
          autofocus: true,
          child: MouseRegion(
            cursor: _overlaysVisible
                ? MouseCursor.defer
                : SystemMouseCursors.none,
            onHover: (_) => _wake(),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      Listener(
                        onPointerSignal: (event) {
                          if (event is PointerScrollEvent && !isVideo) {
                            _onScroll(event);
                          }
                        },
                        child: InteractiveViewer(
                          transformationController: _transform,
                          maxScale: 10,
                          minScale: 0.5,
                          panEnabled: true,
                          scaleEnabled: !isVideo,
                          child: Center(
                            child: isVideo
                                ? VideoPlayerView(
                                    gallery: widget.gallery,
                                    entry: entry,
                                  )
                                : ViewerImage(
                                    gallery: widget.gallery,
                                    entry: entry,
                                  ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: MouseRegion(
                          onEnter: (_) => _holdOverlay(),
                          onExit: (_) => _releaseOverlay(),
                          child: AnimatedOpacity(
                            opacity: _overlaysVisible ? 1 : 0,
                            duration: const Duration(milliseconds: 250),
                            child: Container(
                              // macOS 红绿灯悬于内容区左上角，顶栏下移避让。
                              padding: defaultTargetPlatform ==
                                      TargetPlatform.macOS
                                  ? const EdgeInsets.fromLTRB(8, 8, 12, 12)
                                      .copyWith(
                                      top: 32,
                                    )
                                  : const EdgeInsets.fromLTRB(8, 8, 12, 12),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: <Color>[
                                    Colors.black54,
                                    Colors.transparent
                                  ],
                                ),
                              ),
                              child: Row(
                                children: <Widget>[
                                  IconButton(
                                    icon: const Icon(Icons.arrow_back,
                                        color: Colors.white),
                                    onPressed: widget.onBack,
                                  ),
                                  if (index >= 0)
                                    Text(
                                      '${index + 1} / ${widget.sequence.length}',
                                      style: const TextStyle(
                                          color: Colors.white70, fontSize: 13),
                                    ),
                                  const Spacer(),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        color: Colors.white),
                                    tooltip: '删除',
                                    onPressed: widget.onDelete,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: MouseRegion(
                          onEnter: (_) => _holdOverlay(),
                          onExit: (_) => _releaseOverlay(),
                          child: AnimatedOpacity(
                            opacity: _overlaysVisible ? 1 : 0,
                            duration: const Duration(milliseconds: 250),
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(16, 30, 16, 16),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: <Color>[
                                    Colors.transparent,
                                    Colors.black54
                                  ],
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: <Widget>[
                                  OverlayAction(
                                    icon: Icons.copy_outlined,
                                    label: _copied ? '已复制' : '复制',
                                    onTap: _copyCurrent,
                                  ),
                                  const SizedBox(width: 26),
                                  DownloadOverlayAction(
                                    gallery: widget.gallery,
                                    entry: entry,
                                  ),
                                  const SizedBox(width: 26),
                                  OverlayAction(
                                    icon: Icons.arrow_forward,
                                    label: '下一张',
                                    onTap: widget.onNext,
                                  ),
                                  const SizedBox(width: 26),
                                  OverlayAction(
                                    icon: Icons.delete_outline,
                                    label: '删除',
                                    onTap: widget.onDelete,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                InfoPanel(gallery: widget.gallery, entry: entry),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
