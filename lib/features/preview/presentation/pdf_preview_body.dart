import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../workspace/domain/file_item.dart';

/// PDF 预览组件：缓存/流式下载得到本地文件后交给 pdfrx 连续滚动渲染，
/// 支持双指缩放，底部悬浮页码指示（"x / N"）。
class PdfPreviewBody extends StatefulWidget {
  const PdfPreviewBody({
    super.key,
    required this.item,
    required this.loader,
  });

  final FileItem item;

  /// 返回可直接由 pdfrx 打开的本地 PDF 文件（内部处理缓存与下载）。
  final Future<File> Function(FileItem item) loader;

  @override
  State<PdfPreviewBody> createState() => _PdfPreviewBodyState();
}

class _PdfPreviewBodyState extends State<PdfPreviewBody> {
  final PdfViewerController _controller = PdfViewerController();

  File? _documentFile;
  int _loadSeq = 0;
  bool _loading = true;
  bool _loadFailed = false;
  int _pageNumber = 1;
  int _pageCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PdfPreviewBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path) {
      _load();
    }
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _loadFailed = false;
      _documentFile = null;
      _pageNumber = 1;
      _pageCount = 0;
    });
    try {
      final file = await widget.loader(widget.item);
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _documentFile = file;
      });
    } catch (error) {
      if (!mounted || seq != _loadSeq) return;
      debugPrint('PDF 预览加载失败：${widget.item.path}（$error）');
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  void _retry() {
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadFailed || _documentFile == null) {
      return _errorState(theme);
    }
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: PdfViewer.file(
            _documentFile!.path,
            controller: _controller,
            params: PdfViewerParams(
              onPageChanged: (pageNumber) {
                if (!mounted || pageNumber == _pageNumber) return;
                setState(() {
                  if (pageNumber != null) _pageNumber = pageNumber;
                });
              },
              onViewerReady: (document, controller) {
                if (!mounted) return;
                setState(() => _pageCount = document.pages.length);
              },
            ),
          ),
        ),
        if (_pageCount > 0)
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
                  '$_pageNumber / $_pageCount',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _errorState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.error_outline, size: 72),
          const SizedBox(height: 12),
          Text('PDF 预览加载失败', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _retry, child: const Text('重试')),
        ],
      ),
    );
  }
}
