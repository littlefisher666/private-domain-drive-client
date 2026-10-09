import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/utils/download_directory.dart';
import '../../../app/theme/cupertino_desktop.dart';
import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../workspace/domain/file_item.dart';
import '../domain/preview_type.dart';
import '../infrastructure/text_preview_loader.dart';
import 'audio_preview_body.dart';
import 'csv_preview_body.dart';
import 'markdown_preview_body.dart';
import 'pdf_preview_body.dart';
import 'text_preview_body.dart';

class PreviewPageArguments {
  const PreviewPageArguments({
    required this.fileName,
    required this.filePath,
    this.imageFiles = const <FileItem>[],
    this.displayPaths = const <String, String>{},
  });

  final String fileName;
  final String filePath;
  final List<FileItem> imageFiles;

  /// 对象实际路径 -> 界面展示路径（回收站等对象真实存储位置与原位置不一致时使用）。
  final Map<String, String> displayPaths;
}

class PreviewPage extends StatefulWidget {
  const PreviewPage({super.key, this.arguments});

  final PreviewPageArguments? arguments;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  static const double _swipeVelocityThreshold = 120;

  int _index = 0;
  Offset _enterOffset = const Offset(1, 0);

  List<FileItem> get _images {
    final args = widget.arguments;
    if (args == null) return const <FileItem>[];
    return args.imageFiles
        .where((item) =>
            !item.isDirectory &&
            PreviewTypeResolver.fromFileName(item.name) == PreviewType.image)
        .toList(growable: false);
  }

  FileItem get _currentItem {
    final args = widget.arguments;
    final images = _images;
    if (args == null || images.isEmpty) {
      return FileItem(
        path: args?.filePath ?? 'shared/preview.txt',
        name: args?.fileName ?? 'preview.txt',
        isDirectory: false,
      );
    }
    return images[_index.clamp(0, images.length - 1)];
  }

  @override
  void initState() {
    super.initState();
    _resolveInitialIndex();
  }

  @override
  void didUpdateWidget(covariant PreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolveInitialIndex();
  }

  void _resolveInitialIndex() {
    final args = widget.arguments;
    if (args == null) return;
    final index = _images.indexWhere((item) => item.path == args.filePath);
    _index = index < 0 ? 0 : index;
  }

  void _onSwipe(double velocity, bool vertical) {
    final images = _images;
    if (images.length < 2) return;
    if (velocity.abs() < _swipeVelocityThreshold) return;
    // 左滑/上滑（velocity < 0）切下一张，右滑/下滑（velocity > 0）切上一张；
    // 新图从滑动方向进入，旧图反向滑出。
    final forward = velocity < 0;
    setState(() {
      _enterOffset = vertical
          ? (forward ? const Offset(0, 1) : const Offset(0, -1))
          : (forward ? const Offset(1, 0) : const Offset(-1, 0));
      _index = (_index + (forward ? 1 : -1)) % images.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentItem = _currentItem;
    final previewType = PreviewTypeResolver.fromFileName(currentItem.name);
    final images = _images;
    final controller = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 图片预览采用相册式纯黑沉浸界面，其他类型保持常规页面样式。
    final immersive = previewType == PreviewType.image;
    // macOS 红绿灯悬于内容区左上角（fullSizeContentView），顶栏下移避让。
    final topInset = defaultTargetPlatform == TargetPlatform.macOS
        ? CupertinoDesktopTokens.titleBarHeight
        : 0.0;

    return Scaffold(
      backgroundColor: immersive ? Colors.black : null,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(kToolbarHeight + topInset),
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: AppBar(
            backgroundColor: immersive ? Colors.black : null,
            foregroundColor: immersive ? Colors.white : null,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  currentItem.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: immersive ? Colors.white : null,
                  ),
                ),
                Text(
                  controller.displayPath(
                    widget.arguments?.displayPaths[currentItem.path] ??
                        currentItem.path,
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: immersive ? Colors.white70 : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              if (controller.capabilities.download)
                IconButton(
                  tooltip: '下载',
                  onPressed: () async {
                    try {
                      final directory = await selectDownloadDirectory();
                      if (directory == null) return;
                      controller.enqueueDownload(
                        FileItem(
                          path: currentItem.path,
                          name: currentItem.name,
                          isDirectory: false,
                        ),
                        targetDirectory: directory,
                      );
                      if (context.mounted) {
                        AppFeedback.showSnack(
                            context, '已加入下载队列：${currentItem.name}');
                      }
                    } catch (error) {
                      if (context.mounted) {
                        AppFeedback.showSnack(
                          context,
                          error.toString().replaceFirst('Bad state: ', ''),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.download_outlined),
                ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: immersive
            ? _PreviewBody(
                previewType: previewType,
                fileName: currentItem.name,
                filePath: currentItem.path,
                imageLoader: controller.loadImagePreview,
                thumbnailLoader: controller.loadThumbnail,
                imagePositionText: images.length > 1
                    ? '${_index + 1} / ${images.length}'
                    : null,
                onImageSwipe: images.length > 1 ? _onSwipe : null,
                imageTransitionOffset: _enterOffset,
                documentLoader: controller.loadPdfDocument,
                textLoaderFactory: controller.createTextPreviewLoader,
                mediaUrlLoader: controller.presignMediaUrl,
              )
            : _PreviewBody(
                previewType: previewType,
                fileName: currentItem.name,
                filePath: currentItem.path,
                imageLoader: controller.loadImagePreview,
                documentLoader: controller.loadPdfDocument,
                textLoaderFactory: controller.createTextPreviewLoader,
                mediaUrlLoader: controller.presignMediaUrl,
              ),
      ),
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({
    required this.previewType,
    required this.fileName,
    required this.filePath,
    required this.imageLoader,
    required this.documentLoader,
    required this.textLoaderFactory,
    required this.mediaUrlLoader,
    this.imagePositionText,
    this.onImageSwipe,
    this.imageTransitionOffset = const Offset(1, 0),
    this.thumbnailLoader,
  });

  final PreviewType previewType;
  final String fileName;
  final String filePath;
  final Future<List<int>> Function(FileItem item) imageLoader;
  final Future<File> Function(FileItem item) documentLoader;
  final TextPreviewLoader Function(FileItem item) textLoaderFactory;
  final Future<String> Function(FileItem item) mediaUrlLoader;
  final String? imagePositionText;
  final void Function(double velocity, bool vertical)? onImageSwipe;
  final Offset imageTransitionOffset;

  /// 缩略图加载器（本地缓存命中时近乎即时返回），
  /// 用于原图未就绪时先展示低清画面。
  final Future<List<int>> Function(FileItem item)? thumbnailLoader;

  FileItem get _item => FileItem(
        path: filePath,
        name: fileName,
        isDirectory: false,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    switch (previewType) {
      case PreviewType.image:
        return _ImagePreviewBody(
          item: _item,
          loader: imageLoader,
          thumbnailLoader: thumbnailLoader,
          positionText: imagePositionText,
          onSwipe: onImageSwipe,
          transitionOffset: imageTransitionOffset,
        );
      case PreviewType.pdf:
        return PdfPreviewBody(
          item: _item,
          loader: documentLoader,
        );
      case PreviewType.markdown:
        return MarkdownPreviewBody(
          item: _item,
          loaderFactory: textLoaderFactory,
        );
      case PreviewType.csv:
        return CsvPreviewBody(
          item: _item,
          loaderFactory: textLoaderFactory,
        );
      case PreviewType.text:
        return TextPreviewBody(
          item: _item,
          loaderFactory: textLoaderFactory,
        );
      case PreviewType.audio:
        return AudioPreviewBody(
          item: _item,
          urlLoader: mediaUrlLoader,
        );
      case PreviewType.unsupported:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.block_outlined, size: 56, color: scheme.error),
              const SizedBox(height: 12),
              Text('暂不支持预览', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                '文件：$fileName\n当前类型仅支持下载。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        );
    }
  }
}

class _HiResLoadingBadge extends StatelessWidget {
  const _HiResLoadingBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        shape: BoxShape.circle,
      ),
      child: const Padding(
        padding: EdgeInsets.all(9),
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _ImagePreviewBody extends StatefulWidget {
  const _ImagePreviewBody({
    required this.item,
    required this.loader,
    this.thumbnailLoader,
    this.positionText,
    this.onSwipe,
    this.transitionOffset = const Offset(1, 0),
  });

  final FileItem item;
  final Future<List<int>> Function(FileItem item) loader;
  final Future<List<int>> Function(FileItem item)? thumbnailLoader;
  final String? positionText;
  final void Function(double velocity, bool vertical)? onSwipe;

  /// 新图片进入屏幕时的起始偏移（相对自身尺寸），决定切换动画的推动方向。
  final Offset transitionOffset;

  @override
  State<_ImagePreviewBody> createState() => _ImagePreviewBodyState();
}

class _ImagePreviewBodyState extends State<_ImagePreviewBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _transition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );

  int _loadSeq = 0;
  bool _loadFailed = false;
  bool _hiResLoading = false;
  Uint8List? _displayedBytes;
  String? _displayedPath;
  Uint8List? _outgoingBytes;
  Uint8List? _incomingBytes;
  String? _incomingPath;
  Offset _exitOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _transition.addStatusListener(_handleTransitionStatus);
    _load(widget.item, animate: false);
  }

  @override
  void didUpdateWidget(covariant _ImagePreviewBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path) {
      _load(widget.item);
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
      _displayedPath = _incomingPath;
      _outgoingBytes = null;
      _incomingBytes = null;
      _incomingPath = null;
    });
  }

  /// 并发加载缩略图与原图：缩略图就绪立即展示（含推动画），
  /// 原图就绪后原地升级清晰度；原图失败时保留缩略图画面。
  void _load(FileItem item, {bool animate = true}) {
    final seq = ++_loadSeq;
    _hiResLoading = true;
    var hiResApplied = false;

    widget.thumbnailLoader?.call(item).then((bytes) {
      if (!mounted ||
          seq != _loadSeq ||
          hiResApplied ||
          bytes.isEmpty ||
          _displayedPath == item.path ||
          _incomingPath == item.path) {
        return;
      }
      final data = Uint8List.fromList(bytes);
      if (!animate || _displayedPath == null) {
        setState(() {
          _loadFailed = false;
          _displayedBytes = data;
          _displayedPath = item.path;
        });
        return;
      }
      _startTransition(item.path, data);
    }).catchError((Object _) {
      // 缩略图不可用时静默降级，等待原图加载结果。
    });

    widget.loader(item).then((bytes) {
      if (!mounted || seq != _loadSeq) return;
      if (bytes.isEmpty) {
        // 空响应当作失败处理，避免 loading 徽标永久停留。
        _hiResLoading = false;
        if (_displayedBytes == null) {
          setState(() => _loadFailed = true);
        }
        return;
      }
      hiResApplied = true;
      _hiResLoading = false;
      final data = Uint8List.fromList(bytes);
      if (_incomingPath == item.path) {
        setState(() => _incomingBytes = data);
      } else if (_displayedPath == item.path) {
        setState(() => _displayedBytes = data);
      } else if (!animate || _displayedPath == null) {
        setState(() {
          _loadFailed = false;
          _displayedBytes = data;
          _displayedPath = item.path;
        });
      } else {
        _startTransition(item.path, data);
      }
    }).catchError((Object _) {
      if (!mounted || seq != _loadSeq) return;
      _hiResLoading = false;
      if (_displayedBytes == null) {
        setState(() => _loadFailed = true);
      }
    });
  }

  void _startTransition(String path, Uint8List bytes) {
    setState(() {
      _loadFailed = false;
      if (_incomingBytes != null) {
        // 上一次切换动画未结束又触发切换时，先落定当前帧再开始新动画。
        _displayedBytes = _incomingBytes;
        _displayedPath = _incomingPath;
      }
      _outgoingBytes = _displayedBytes;
      _incomingBytes = bytes;
      _incomingPath = path;
      _exitOffset = -widget.transitionOffset;
    });
    _transition.forward(from: 0);
  }

  void _retry() {
    _load(widget.item, animate: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragEnd: widget.onSwipe == null
                ? null
                : (details) =>
                    widget.onSwipe!(details.velocity.pixelsPerSecond.dx, false),
            onVerticalDragEnd: widget.onSwipe == null
                ? null
                : (details) =>
                    widget.onSwipe!(details.velocity.pixelsPerSecond.dy, true),
            child: _buildImageArea(theme),
          ),
        ),
        if (widget.positionText != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  widget.positionText!,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        // 仅当新图内容已开始展示（缩略图或原图进入动画/已显示）时才提示加载中，
        // 避免徽标出现在尚未切走的旧图上。
        if (_hiResLoading &&
            (_incomingPath == widget.item.path ||
                _displayedPath == widget.item.path))
          const Positioned(
            right: 16,
            bottom: 16,
            child: _HiResLoadingBadge(),
          ),
      ],
    );
  }

  Widget _buildImageArea(ThemeData theme) {
    if (_displayedBytes == null) {
      if (_loadFailed) return _errorState(theme);
      return const Center(child: CircularProgressIndicator());
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
              begin: widget.transitionOffset,
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
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
    );
  }

  Widget _errorState(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.broken_image_outlined, size: 72),
        const SizedBox(height: 12),
        Text('图片预览加载失败', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _retry, child: const Text('重试')),
      ],
    );
  }
}
