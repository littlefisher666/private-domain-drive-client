import 'package:flutter/material.dart';

import '../../domain/file_item.dart';
import '../../../../shared/widgets/file_icon.dart';

/// 移动端相册式流式缩略图布局：每行统一行高，条目宽度按图片宽高比
/// 分配并撑满整行，行与行之间只保留极小间距，与系统相册的“照片”页一致。
class MobileUniformGrid extends StatelessWidget {
  const MobileUniformGrid({
    super.key,
    required this.items,
    required this.selectedPath,
    required this.selectedPaths,
    required this.multiSelecting,
    required this.subtitleBuilder,
    required this.thumbnailLoader,
    required this.thumbnailCacheNamespace,
    required this.onOpen,
    required this.onMore,
    required this.onSelect,
    required this.onToggle,
    this.onLongPress,
    this.bottomPadding = 12,
  });

  final List<FileItem> items;
  final String? selectedPath;
  final Set<String> selectedPaths;
  final bool multiSelecting;
  final String Function(FileItem) subtitleBuilder;
  final Future<List<int>> Function(FileItem item) thumbnailLoader;
  final String thumbnailCacheNamespace;
  final ValueChanged<FileItem> onOpen;
  final ValueChanged<FileItem> onMore;
  final ValueChanged<FileItem> onSelect;
  final ValueChanged<FileItem> onToggle;
  final ValueChanged<FileItem>? onLongPress;
  final double bottomPadding;

  static const _spacing = 3.0;

  /// 缩略图目标格子尺寸；列数按可用宽度自动推算。
  static const _maxTileExtent = 68.0;

  @override
  Widget build(BuildContext context) {
    final images = <FileItem>[];
    final others = <FileItem>[];
    for (final item in items) {
      if (!item.isDirectory && item.kind == FileKind.image) {
        images.add(item);
      } else {
        others.add(item);
      }
    }
    return CustomScrollView(
      slivers: <Widget>[
        if (images.isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.only(bottom: others.isEmpty ? 12 : 8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: _maxTileExtent,
                mainAxisSpacing: _spacing,
                crossAxisSpacing: _spacing,
                childAspectRatio: 1,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildTile(context, images[index]),
                childCount: images.length,
              ),
            ),
          ),
        if (others.isNotEmpty)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final item = others[index];
                return _buildOtherRow(context, item);
              },
              childCount: others.length,
            ),
          ),
        SliverToBoxAdapter(child: SizedBox(height: bottomPadding)),
      ],
    );
  }

  Widget _buildOtherRow(BuildContext context, FileItem item) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      contentPadding: const EdgeInsets.only(left: 12, right: 4),
      horizontalTitleGap: 10,
      minLeadingWidth: 28,
      minVerticalPadding: 5,
      leading: multiSelecting && !item.isAlias
          ? SizedBox(
              width: 28,
              height: 28,
              child: Checkbox(
                value: selectedPaths.contains(item.path),
                visualDensity: VisualDensity.compact,
                onChanged: (_) => onToggle(item),
              ),
            )
          : FileTypeIcon(item: item, size: 24),
      title: Text(
        item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
      ),
      subtitle: Text(
        subtitleBuilder(item),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
      ),
      onTap: () {
        onSelect(item);
        if (!multiSelecting) onOpen(item);
      },
      onLongPress: () => (onLongPress ?? onToggle)(item),
      trailing: IconButton(
        tooltip: '更多',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        onPressed: () => onMore(item),
        icon: const Icon(Icons.more_vert, size: 20),
      ),
    );
  }

  Widget _buildTile(BuildContext context, FileItem item) {
    final selected = selectedPaths.isNotEmpty
        ? !item.isAlias && selectedPaths.contains(item.path)
        : item.path == selectedPath;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () {
        onSelect(item);
        if (!multiSelecting) onOpen(item);
      },
      onLongPress: () => (onLongPress ?? onToggle)(item),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: FileTypeThumbnail(
              item: item,
              height: double.infinity,
              loader: thumbnailLoader,
              cacheNamespace: thumbnailCacheNamespace,
            ),
          ),
          if (selected)
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.08),
                border: Border.all(color: scheme.primary, width: 2),
              ),
            ),
          if (multiSelecting)
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Checkbox(
                  value: selected,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (_) => onToggle(item),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
