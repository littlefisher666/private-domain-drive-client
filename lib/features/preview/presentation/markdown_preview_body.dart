import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../workspace/domain/file_item.dart';
import '../infrastructure/text_preview_loader.dart';

/// Markdown 预览组件：默认渲染视图（标题/列表/代码块/链接等），
/// 顶栏提供「渲染/源码」切换；源码复用等宽文本展示。
class MarkdownPreviewBody extends StatefulWidget {
  const MarkdownPreviewBody({
    super.key,
    required this.item,
    required this.loaderFactory,
  });

  final FileItem item;

  final TextPreviewLoader Function(FileItem item) loaderFactory;

  @override
  State<MarkdownPreviewBody> createState() => _MarkdownPreviewBodyState();
}

class _MarkdownPreviewBodyState extends State<MarkdownPreviewBody> {
  final ScrollController _scrollController = ScrollController();

  TextPreviewLoader? _loader;
  final StringBuffer _text = StringBuffer();
  int _loadSeq = 0;
  bool _showSource = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _failed = false;
  bool _complete = false;
  bool _reachedLimit = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _reset();
  }

  @override
  void didUpdateWidget(covariant MarkdownPreviewBody oldWidget) {
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
      });
    } catch (error) {
      if (!mounted || seq != _loadSeq) return;
      debugPrint('Markdown 预览加载失败：${widget.item.path}（$error）');
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
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 72),
            const SizedBox(height: 12),
            Text('Markdown 预览加载失败', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _retry, child: const Text('重试')),
          ],
        ),
      );
    }
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SegmentedButton<bool>(
            segments: const <ButtonSegment<bool>>[
              ButtonSegment<bool>(
                value: false,
                icon: Icon(Icons.article_outlined),
                label: Text('渲染'),
              ),
              ButtonSegment<bool>(
                value: true,
                icon: Icon(Icons.code_outlined),
                label: Text('源码'),
              ),
            ],
            selected: {_showSource},
            onSelectionChanged: (selection) =>
                setState(() => _showSource = selection.first),
          ),
        ),
        Expanded(
          child: _showSource ? _buildSource(theme) : _buildRendered(theme),
        ),
      ],
    );
  }

  Widget _buildRendered(ThemeData theme) {
    return Markdown(
      controller: _scrollController,
      data: _text.toString(),
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              width: 3,
              color: theme.colorScheme.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSource(ThemeData theme) {
    return SingleChildScrollView(
      controller: _scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SelectionArea(
            child: Text(
              _text.toString(),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                height: 1.45,
              ),
            ),
          ),
          ..._footers(theme),
        ],
      ),
    );
  }

  List<Widget> _footers(ThemeData theme) {
    final scheme = theme.colorScheme;
    return <Widget>[
      if (_reachedLimit)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '内容过大，已展示前 20MB，请下载查看完整文件。',
            style:
                theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
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
    ];
  }
}
