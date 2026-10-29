import 'package:flutter/material.dart';

/// 图片查看区域的缩放容器：1x–4x 捏合、双击在 1x 与预设比例间切换、
/// 放大后单指平移；仅在原始比例且单指滑动时把滑动速度交给调用方切换图片。
///
/// 预览页与相册查看器共用，`resetToken` 变化（切图）时重置缩放与位移。
class ZoomableImageArea extends StatefulWidget {
  const ZoomableImageArea({
    super.key,
    required this.child,
    this.resetToken,
    this.onSwipe,
    this.minScale = 1,
    this.maxScale = 4,
    this.doubleTapScale = 2.5,
  });

  final Widget child;

  /// 图片标识；变化时把变换矩阵重置为单位矩阵。
  final Object? resetToken;

  /// 原始比例下的单指滑动结束回调（速度单位 px/s）。
  final void Function(double velocity, bool vertical)? onSwipe;

  final double minScale;
  final double maxScale;
  final double doubleTapScale;

  @override
  State<ZoomableImageArea> createState() => _ZoomableImageAreaState();
}

class _ZoomableImageAreaState extends State<ZoomableImageArea>
    with SingleTickerProviderStateMixin {
  final TransformationController _controller = TransformationController();
  late final AnimationController _zoomAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _zoomTween;

  bool _zoomed = false;
  bool _startedAtMinScale = false;
  int _maxPointerCount = 1;
  Offset? _doubleTapPosition;

  double get _scale => _controller.value.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleTransformChanged);
    _zoomAnimation.addListener(_handleZoomTick);
  }

  @override
  void didUpdateWidget(covariant ZoomableImageArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetToken != widget.resetToken) {
      _reset();
    }
  }

  @override
  void dispose() {
    _zoomAnimation.dispose();
    _controller.removeListener(_handleTransformChanged);
    _controller.dispose();
    super.dispose();
  }

  void _handleTransformChanged() {
    final zoomed = _scale > widget.minScale * 1.001;
    if (zoomed != _zoomed) {
      setState(() => _zoomed = zoomed);
    }
  }

  void _handleZoomTick() {
    final tween = _zoomTween;
    if (tween != null) {
      _controller.value = tween.value;
    }
  }

  void _reset() {
    _zoomAnimation.stop();
    _zoomTween = null;
    _controller.value = Matrix4.identity();
  }

  void _onInteractionStart(ScaleStartDetails details) {
    _zoomAnimation.stop();
    _zoomTween = null;
    _startedAtMinScale = !_zoomed;
    _maxPointerCount = details.pointerCount;
  }

  void _onInteractionUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount > _maxPointerCount) {
      _maxPointerCount = details.pointerCount;
    }
  }

  void _onInteractionEnd(ScaleEndDetails details) {
    final onSwipe = widget.onSwipe;
    if (onSwipe == null ||
        !_startedAtMinScale ||
        _zoomed ||
        _maxPointerCount > 1) {
      return;
    }
    final velocity = details.velocity.pixelsPerSecond;
    if (velocity.dx.abs() < velocity.dy.abs()) {
      onSwipe(velocity.dy, true);
    } else {
      onSwipe(velocity.dx, false);
    }
  }

  void _onDoubleTapDown(TapDownDetails details) {
    _doubleTapPosition = details.localPosition;
  }

  void _onDoubleTap() {
    if (_zoomed) {
      _animateTo(Matrix4.identity());
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    final position = _doubleTapPosition ??
        (box == null ? Offset.zero : box.size.center(Offset.zero));
    final scale = widget.doubleTapScale;
    final target = Matrix4.identity()
      ..translateByDouble(
        -position.dx * (scale - 1),
        -position.dy * (scale - 1),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
    _animateTo(target);
  }

  void _animateTo(Matrix4 target) {
    _zoomTween = Matrix4Tween(
      begin: _controller.value.clone(),
      end: target,
    ).animate(
      CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeOutCubic),
    );
    _zoomAnimation.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _controller,
      minScale: widget.minScale,
      maxScale: widget.maxScale,
      panEnabled: _zoomed,
      scaleEnabled: true,
      onInteractionStart: _onInteractionStart,
      onInteractionUpdate: _onInteractionUpdate,
      onInteractionEnd: _onInteractionEnd,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: _onDoubleTapDown,
        onDoubleTap: _onDoubleTap,
        child: widget.child,
      ),
    );
  }
}
