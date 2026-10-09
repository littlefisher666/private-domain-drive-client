import 'package:flutter/material.dart';

import '../../workspace/domain/file_item.dart';
import '../infrastructure/text_preview_loader.dart';

/// 纯文本展示视图：等宽字体、可滚动、内容可选择复制。
/// 供文本预览、Markdown 源码视图等复用。
class MonospaceTextView extends StatelessWidget {
  const MonospaceTextView({super.key, required this.text, this.footer});

  final String text;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SelectionArea(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                height: 1.45,
              ),
            ),
          ),
          if (footer != null) footer!,
        ],
      ),
    );
  }
}

/// 文本预览组件：分段加载 + 滚动接近底部自动续载，达到累计上限后
/// 提示下载查看完整文件。
class TextPreviewBody extends StatefulWidget {
  const TextPreviewBody({
    super.key,
    required this.item,
    required this.loaderFactory,
  });

  final FileItem item;

  /// 创建文本加载器（内部持有会话与 OSS 客户端）。
  final TextPreviewLoader Function(FileItem item) loaderFactory;

  @override
  State<TextPreviewBody> createState() => _TextPreviewBodyState();
}

class _TextPreviewBodyState extends State<TextPreviewBody> {
  final ScrollController _scrollController = ScrollController();

  TextPreviewLoader? _loader;
  final StringBuffer _text = StringBuffer();
  int _loadSeq = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _failed = false;
  bool _complete = false;
  bool _reachedLimit = false;
  bool _encodingUnknown = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _reset();
  }

  @override
  void didUpdateWidget(covariant TextPreviewBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path) {
      _reset();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _reset() {
    final seq = ++_loadSeq;
    _text.clear();
    setState(() {
      _loading = true;
      _loadingMore = false;
      _failed = false;
      _complete = false;
      _reachedLimit = false;
      _encodingUnknown = false;
    });
    try {
      _loader = widget.loaderFactory(widget.item);
    } catch (error) {
      // 会话缺失等同步失败直接进入错误重试状态。
      _loader = null;
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    _loadMore(seq);
  }

  void _onScroll() {
    if (_loading || _loadingMore || _failed || _complete || _reachedLimit) {
      return;
    }
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels < 600) {
      _loadMore(_loadSeq);
    }
  }

  Future<void> _loadMore(int seq) async {
    final loader = _loader;
    if (loader == null || _loadingMore || _failed) return;
    setState(() => _loadingMore = true);
    try {
      final appended = await loader.loadMore();
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _text.write(appended);
        _complete = loader.complete;
        _reachedLimit = loader.reachedLimit;
        _encodingUnknown = loader.encodingUnknown;
      });
    } catch (error) {
      if (!mounted || seq != _loadSeq) return;
      debugPrint('文本预览加载失败：${widget.item.path}（$error）');
      setState(() {
        _loading = false;
        _loadingMore = false;
        _failed = _text.isEmpty;
      });
    }
  }

  void _retry() {
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return _errorState(context);
    }
    return Scrollbar(
      controller: _scrollController,
      child: SingleChildScrollView(
        controller: _scrollController,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SelectionArea(
              child: Text(
                _text.toString(),
                style: _monospaceStyle(context),
              ),
            ),
            if (_encodingUnknown)
              _noticeBanner(context, '文件编码无法识别，内容可能存在乱码。'),
            if (_reachedLimit)
              _noticeBanner(context, '内容过大，已展示前 20MB，请下载查看完整文件。'),
            if (_loadingMore)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _errorState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.error_outline, size: 72),
          const SizedBox(height: 12),
          Text('文本预览加载失败', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _retry, child: const Text('重试')),
        ],
      ),
    );
  }
}

TextStyle? _monospaceStyle(BuildContext context) {
  return Theme.of(context).textTheme.bodyMedium?.copyWith(
        fontFamily: 'monospace',
        height: 1.45,
      );
}

Widget _noticeBanner(BuildContext context, String message) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.all(12),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      message,
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: scheme.onSurfaceVariant),
    ),
  );
}
