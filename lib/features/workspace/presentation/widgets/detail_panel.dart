import 'package:flutter/material.dart';

import '../../../../shared/state/app_scope.dart';
import '../../../../core/utils/file_size_formatter.dart';
import '../../application/workspace_controller.dart';
import '../../domain/file_item.dart';
import '../../../../shared/widgets/file_icon.dart';

/// 桌面端右侧详情面板：展示当前选中条目的元信息。
class DetailPanel extends StatelessWidget {
  const DetailPanel({super.key, required this.item, this.directorySize});

  final FileItem? item;
  final DirectorySizeState? directorySize;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(
          left: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: scheme.outlineVariant),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '详情预览',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: item == null
                ? Center(
                    child: Text(
                      '选中文件后展示详情',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: <Widget>[
                      FileTypeThumb(item: item!, height: 150),
                      const SizedBox(height: 14),
                      Text(
                        item!.name,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _kv(context, '类型', item!.typeLabel),
                      _kv(
                        context,
                        '大小',
                        item!.isDirectory
                            ? _directorySizeLabel(directorySize)
                            : FileSizeFormatter.format(item!.size ?? 0),
                      ),
                      _kv(context, '路径', controller.workspaceController.displayPath(item!.path)),
                      if (item!.isAlias)
                        _kv(context, '创建者', item!.createdBy ?? ''),
                      _kv(
                        context,
                        '更新',
                        item!.updatedAt == null
                            ? '—'
                            : _formatTime(item!.updatedAt!),
                      ),
                      if (item!.kind == FileKind.image)
                        _kv(
                          context,
                          '拍摄',
                          item!.takenAt == null
                              ? ''
                              : _formatTime(item!.takenAt!),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _directorySizeLabel(DirectorySizeState? state) {
    if (state == null || state.isLoading) return '正在计算…';
    if (state.size == null) return '暂无法获取';
    return FileSizeFormatter.format(state.size!);
  }

  String _formatTime(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd $hh:$mi';
  }
}
