import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/state/app_controller.dart';
import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../transfer/domain/transfer_task.dart';
import '../application/gallery_controller.dart';
import '../domain/photo_entry.dart';
import 'gallery_scope.dart';

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
      return _DesktopViewer(
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
    return _MobileViewer(
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

/// 查找与对象 key 相关的最近下载任务（判断下载原图状态用）。
TransferTask? _downloadTaskFor(List<TransferTask> tasks, PhotoEntry entry) {
  TransferTask? latest;
  for (final task in tasks) {
    if (task.type != TransferTaskType.download) continue;
    if (task.sourcePath != entry.key) continue;
    latest = task;
  }
  return latest;
}

// ============================== 移动端查看器 ==============================

class _MobileViewer extends StatefulWidget {
  const _MobileViewer({
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
  State<_MobileViewer> createState() => _MobileViewerState();
}

class _MobileViewerState extends State<_MobileViewer> {
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
    final dateText = _formatTakenAt(entry.takenAt);
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
                  ? _VideoStillView(gallery: widget.gallery, entry: entry)
                  : _ViewerImage(
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
                    _DownloadButton(gallery: widget.gallery, entry: entry),
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
              child: _MobileDetailSheet(
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

// ============================== 桌面端查看器 ==============================

/// 移动端照片详情面板（上滑呼出、下滑收起）。
class _MobileDetailSheet extends StatelessWidget {
  const _MobileDetailSheet({
    required this.gallery,
    required this.entry,
    required this.onClose,
  });

  final GalleryController gallery;
  final PhotoEntry entry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final cached = gallery.isCached(entry.key);
    final lat = entry.latitude;
    final lon = entry.longitude;

    return Container(
      constraints: const BoxConstraints(maxHeight: 300),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      decoration: const BoxDecoration(
        color: Color(0xFF1F2128),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF4A4E5A),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _group('基础', <(String, String)>[
                    ('拍摄时间', _formatTakenAt(entry.takenAt)),
                    if (entry.width != null && entry.height != null)
                      ('分辨率', '${entry.width} × ${entry.height}'),
                    ('原始大小', FileSizeFormatterLite.format(entry.size)),
                    ('格式', entry.extension.toUpperCase()),
                  ]),
                  _group('来源', <(String, String)>[
                    ('所在目录', app.displayPath(entry.directory)),
                    if (entry.device != null) ('上传设备', entry.device!),
                    ('本机缓存', cached ? '已缓存' : '未缓存'),
                  ]),
                  if (lat != null && lon != null)
                    _group('位置', <(String, String)>[
                      (
                        '拍摄地点',
                        '${lat.abs().toStringAsFixed(4)}° ${lat >= 0 ? 'N' : 'S'}, '
                            '${lon.abs().toStringAsFixed(4)}° ${lon >= 0 ? 'E' : 'W'}'
                      ),
                    ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onClose,
            child: const Text('收起',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _group(String title, List<(String, String)> rows) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF7C828E),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 4),
          for (final (key, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    key,
                    style: const TextStyle(
                        fontSize: 12.5, color: Color(0xFF8D93A1)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      value,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFFE8EAEF),
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DesktopViewer extends StatefulWidget {
  const _DesktopViewer({
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
  final AppController app;
  final PhotoEntry entry;
  final List<PhotoEntry> sequence;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final VoidCallback onDelete;

  @override
  State<_DesktopViewer> createState() => _DesktopViewerState();
}

class _DesktopViewerState extends State<_DesktopViewer> {
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
                                ? _VideoStillView(
                                    gallery: widget.gallery,
                                    entry: entry,
                                  )
                                : _ViewerImage(
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
                                  _OverlayAction(
                                    icon: Icons.copy_outlined,
                                    label: _copied ? '已复制' : '复制',
                                    onTap: _copyCurrent,
                                  ),
                                  const SizedBox(width: 26),
                                  _DownloadOverlayAction(
                                    gallery: widget.gallery,
                                    entry: entry,
                                  ),
                                  const SizedBox(width: 26),
                                  _OverlayAction(
                                    icon: Icons.arrow_forward,
                                    label: '下一张',
                                    onTap: widget.onNext,
                                  ),
                                  const SizedBox(width: 26),
                                  _OverlayAction(
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
                _InfoPanel(gallery: widget.gallery, entry: entry),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OverlayAction extends StatelessWidget {
  const _OverlayAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 20, color: Colors.white.withValues(alpha: 0.9)),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部原图下载操作：展示下载状态（下载中 / 重试）与原图大小。
class _DownloadOverlayAction extends StatelessWidget {
  const _DownloadOverlayAction({required this.gallery, required this.entry});

  final GalleryController gallery;
  final PhotoEntry entry;

  @override
  Widget build(BuildContext context) {
    final cached = gallery.isCached(entry.key);
    if (cached) {
      return const _OverlayAction(
        icon: Icons.check_circle_outline,
        label: '已缓存',
        onTap: _noop,
      );
    }
    final task = _downloadTaskFor(gallery.appTasks, entry);
    final active = task != null &&
        (task.status == TransferTaskStatus.pending ||
            task.status == TransferTaskStatus.running);
    final failed = task?.status == TransferTaskStatus.failed;
    return _OverlayAction(
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

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({required this.gallery, required this.entry});

  final GalleryController gallery;
  final PhotoEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppScope.of(context);
    final cached = gallery.isCached(entry.key);
    final lat = entry.latitude;
    final lon = entry.longitude;

    return Container(
      width: 260,
      color: const Color(0xFF1F2128),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFF30333D)),
              ),
            ),
            alignment: Alignment.centerLeft,
            child: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFE8EAEF),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _infoGroup(
                    theme,
                    '基础',
                    <(String, String)>[
                      ('拍摄时间', _formatTakenAt(entry.takenAt)),
                      if (entry.width != null && entry.height != null)
                        ('分辨率', '${entry.width} × ${entry.height}'),
                      ('原始大小', FileSizeFormatterLite.format(entry.size)),
                      ('格式', entry.extension.toUpperCase()),
                    ],
                  ),
                  _infoGroup(
                    theme,
                    '来源',
                    <(String, String)>[
                      ('所在目录', app.displayPath(entry.directory)),
                      if (entry.device != null) ('上传设备', entry.device!),
                    ],
                    trailing: _cacheRow(cached),
                  ),
                  if (lat != null && lon != null)
                    _infoGroup(
                      theme,
                      '位置',
                      <(String, String)>[
                        (
                          '拍摄地点',
                          '${lat.abs().toStringAsFixed(4)}° ${lat >= 0 ? 'N' : 'S'}, '
                              '${lon.abs().toStringAsFixed(4)}° ${lon >= 0 ? 'E' : 'W'}'
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cacheRow(bool cached) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          const Text('本机缓存',
              style: TextStyle(
                  fontSize: 12.5,
                  height: 1.35,
                  color: Color(0xFF8D93A1))),
          Row(
            children: <Widget>[
              Icon(
                cached ? Icons.check_circle_outline : Icons.cloud_outlined,
                size: 14,
                color:
                    cached ? const Color(0xFF8BD48B) : const Color(0xFFF0B26B),
              ),
              const SizedBox(width: 5),
              Text(
                cached ? '已缓存' : '未缓存',
                style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFFE8EAEF)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoGroup(
    ThemeData theme,
    String title,
    List<(String, String)> rows, {
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.labelSmall?.copyWith(
              color: const Color(0xFF7C828E),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 6),
          for (final (key, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    key,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.35,
                      color: Color(0xFF8D93A1),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      value,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: Color(0xFFE8EAEF),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }
}

// ============================== 共用子组件 ==============================

/// 查看器图片区：已缓存读本地文件秒开；未缓存加载降级预览并触发
/// 后台下载，下载完成（缓存状态变化）后无缝替换为原图。
/// 切换时使用与预览页一致的推移动画。
class _ViewerImage extends StatefulWidget {
  const _ViewerImage({
    required this.gallery,
    required this.entry,
    this.enterOffset = const Offset(1, 0),
  });

  final GalleryController gallery;
  final PhotoEntry entry;

  /// 新图片进入屏幕时的起始偏移（相对自身尺寸）。
  final Offset enterOffset;

  @override
  State<_ViewerImage> createState() => _ViewerImageState();
}

class _ViewerImageState extends State<_ViewerImage>
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
  void didUpdateWidget(covariant _ViewerImage oldWidget) {
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
  }}

/// 视频条目：展示截帧缩略图并提示不支持在线播放，仅提供下载。
class _VideoStillView extends StatefulWidget {
  const _VideoStillView({required this.gallery, required this.entry});

  final GalleryController gallery;
  final PhotoEntry entry;

  @override
  State<_VideoStillView> createState() => _VideoStillViewState();
}

class _VideoStillViewState extends State<_VideoStillView> {
  Uint8List? _frameBytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _VideoStillView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.key != widget.entry.key) {
      setState(() => _frameBytes = null);
      _load();
    }
  }

  Future<void> _load() async {
    final bytes = await widget.gallery.loadThumbObject(widget.entry.thumbKey);
    if (mounted) {
      setState(() => _frameBytes = bytes == null ? null : Uint8List.fromList(bytes));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _frameBytes;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: bytes == null || bytes.isEmpty
                  ? Container(
                      decoration: BoxDecoration(
                        color: Colors.white10,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(
                        child: Icon(Icons.videocam_outlined,
                            size: 64, color: Colors.white38),
                      ),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                          Uint8List.fromList(bytes), fit: BoxFit.contain),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '视频不支持在线播放，可下载原图后本地播放',
            style: TextStyle(color: Colors.white70, fontSize: 12.5),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// 移动端原图下载按钮（主 CTA 样式）。
class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.gallery, required this.entry});

  final GalleryController gallery;
  final PhotoEntry entry;

  @override
  Widget build(BuildContext context) {
    final cached = gallery.isCached(entry.key);
    final task = _downloadTaskFor(gallery.appTasks, entry);
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

String _formatTakenAt(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class FileSizeFormatterLite {
  FileSizeFormatterLite._();

  static String format(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }
}
