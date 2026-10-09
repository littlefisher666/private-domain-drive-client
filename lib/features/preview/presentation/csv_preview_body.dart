import 'package:flutter/material.dart';

import '../../workspace/domain/file_item.dart';
import '../infrastructure/text_preview_loader.dart';

/// CSV 预览组件：轻量解析（支持引号包裹与转义）、首行表头、横纵
/// 可滚动表格（行懒加载）；复用文本分段加载与 20MB 上限策略。
/// 列数严重不规则时回退纯文本展示。
class CsvPreviewBody extends StatefulWidget {
  const CsvPreviewBody({
    super.key,
    required this.item,
    required this.loaderFactory,
  });

  final FileItem item;

  final TextPreviewLoader Function(FileItem item) loaderFactory;

  @override
  State<CsvPreviewBody> createState() => _CsvPreviewBodyState();
}

class _CsvPreviewBodyState extends State<CsvPreviewBody> {
  static const double _columnWidth = 180;

  final ScrollController _verticalController = ScrollController();

  TextPreviewLoader? _loader;
  final StringBuffer _raw = StringBuffer();
  final List<List<String>> _rows = <List<String>>[];
  List<String>? _header;
  int _loadSeq = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _failed = false;
  bool _complete = false;
  bool _reachedLimit = false;
  bool _fallbackToText = false;

  /// 解析游标：_raw 中尚未解析成行的起始字符位置。
  int _parseOffset = 0;
  String _delimiter = ',';

  @override
  void initState() {
    super.initState();
    _verticalController.addListener(_onScroll);
    _reset();
  }

  @override
  void didUpdateWidget(covariant CsvPreviewBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path) {
      _reset();
    }
  }

  @override
  void dispose() {
    _verticalController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loading || _loadingMore || _failed || _complete || _reachedLimit) {
      return;
    }
    if (!_verticalController.hasClients) return;
    final position = _verticalController.position;
    if (position.maxScrollExtent - position.pixels < 600) {
      _loadMore(_loadSeq);
    }
  }

  void _reset() {
    final seq = ++_loadSeq;
    _raw.clear();
    _rows.clear();
    _header = null;
    _parseOffset = 0;
    _delimiter = ',';
    setState(() {
      _loading = true;
      _loadingMore = false;
      _failed = false;
      _complete = false;
      _reachedLimit = false;
      _fallbackToText = false;
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
        _raw.write(appended);
        _complete = loader.complete;
        _reachedLimit = loader.reachedLimit;
        _parseBuffer(isFinal: _complete || _reachedLimit);
      });
    } catch (error) {
      if (!mounted || seq != _loadSeq) return;
      debugPrint('CSV 预览加载失败：${widget.item.path}（$error）');
      setState(() {
        _loading = false;
        _loadingMore = false;
        _failed = _raw.isEmpty;
      });
    }
  }

  /// 解析 _raw 中从 _parseOffset 起的完整行；引号未闭合时停止等待
  /// 更多内容。isFinal 时把剩余内容全部按行解析。
  void _parseBuffer({required bool isFinal}) {
    if (_fallbackToText) return;
    final text = _raw.toString();
    if (_header == null && text.isEmpty) return;

    if (_header == null) {
      _delimiter = _detectDelimiter(text);
    }

    while (_parseOffset < text.length) {
      final result = _parseRow(text, _parseOffset, isFinal: isFinal);
      final row = result.row;
      if (row == null) break;
      _parseOffset = result.nextOffset;
      if (_header == null) {
        _header = row;
      } else {
        _rows.add(row);
      }
    }
    if (!_fallbackToText && _rows.length > 4) {
      _checkColumnConsistency();
    }
  }

  String _detectDelimiter(String text) {
    final firstLineEnd = text.indexOf('\n');
    final firstLine = firstLineEnd < 0 ? text : text.substring(0, firstLineEnd);
    const candidates = <String>[',', ';', '\t'];
    String best = ',';
    var bestCount = 0;
    for (final candidate in candidates) {
      final count = firstLine.split(candidate).length - 1;
      if (count > bestCount) {
        best = candidate;
        bestCount = count;
      }
    }
    return best;
  }

  void _checkColumnConsistency() {
    final columns = _header?.length ?? 0;
    if (columns == 0) return;
    final irregular =
        _rows.where((row) => row.length != columns).length;
    if (irregular > _rows.length * 0.1) {
      _fallbackToText = true;
    }
  }

  _RowParseResult _parseRow(
    String text,
    int start, {
    required bool isFinal,
  }) {
    final fields = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var index = start;
    while (index < text.length) {
      final char = text[index];
      if (inQuotes) {
        if (char == '"') {
          if (index + 1 < text.length && text[index + 1] == '"') {
            field.write('"');
            index += 2;
            continue;
          }
          inQuotes = false;
          index++;
          continue;
        }
        field.write(char);
        index++;
        continue;
      }
      if (char == '"' && field.isEmpty) {
        inQuotes = true;
        index++;
        continue;
      }
      if (char == _delimiter) {
        fields.add(field.toString());
        field.clear();
        index++;
        continue;
      }
      if (char == '\r') {
        index++;
        continue;
      }
      if (char == '\n') {
        index++;
        fields.add(field.toString());
        return _RowParseResult(row: fields, nextOffset: index);
      }
      field.write(char);
      index++;
    }
    // 到达缓冲区末尾：行尚未收到结束换行（或引号未闭合）时一律等待
    // 更多内容；只有 isFinal（文件末尾或到达累计上限）才提交末行。
    if (!isFinal) {
      return const _RowParseResult(row: null, nextOffset: -1);
    }
    fields.add(field.toString());
    return _RowParseResult(row: fields, nextOffset: index);
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
            Text('CSV 预览加载失败', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _retry, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_fallbackToText || _header == null) {
      return _buildFallbackText(theme);
    }
    return _buildTable(theme);
  }

  Widget _buildFallbackText(ThemeData theme) {
    return SingleChildScrollView(
      controller: _verticalController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SelectionArea(
            child: Text(
              _raw.toString(),
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

  Widget _buildTable(ThemeData theme) {
    final columns = _header!.length;
    final tableWidth = columns * _columnWidth;
    final scheme = theme.colorScheme;
    final totalRows = _rows.length + 1; // 含表头行。

    Widget table = ListView.builder(
      controller: _verticalController,
      itemCount: totalRows + 2, // 表头 + 数据行 + 底部提示区。
      itemBuilder: (context, index) {
        if (index >= totalRows) {
          return Column(
            children: _footers(theme),
          );
        }
        final isHeader = index == 0;
        final cells = isHeader ? _header! : _rows[index - 1];
        return Container(
          decoration: BoxDecoration(
            color: isHeader
                ? scheme.surfaceContainerHighest.withValues(alpha: 0.6)
                : (index.isEven
                    ? scheme.surfaceContainerHighest.withValues(alpha: 0.15)
                    : null),
            border: Border(
              bottom: BorderSide(color: scheme.outlineVariant, width: 0.5),
            ),
          ),
          child: Row(
            children: <Widget>[
              for (var column = 0; column < columns; column++)
                SizedBox(
                  width: _columnWidth,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Text(
                      column < cells.length ? cells[column] : '',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: (isHeader
                              ? theme.textTheme.labelLarge
                              : theme.textTheme.bodyMedium)
                          ?.copyWith(
                        fontWeight: isHeader ? FontWeight.w700 : null,
                        fontFamily: isHeader ? null : 'monospace',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );

    if (tableWidth > MediaQuery.sizeOf(context).width) {
      table = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(width: tableWidth, child: table),
      );
    }
    return Scrollbar(
      controller: _verticalController,
      child: table,
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
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
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

class _RowParseResult {
  const _RowParseResult({required this.row, required this.nextOffset});

  final List<String>? row;
  final int nextOffset;
}
