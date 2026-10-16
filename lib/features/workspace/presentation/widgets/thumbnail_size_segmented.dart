import 'package:flutter/material.dart';

import '../../domain/file_item.dart';
import 'seg_button.dart';

/// 缩略图尺寸分段切换控件。
class ThumbnailSizeSegmented extends StatelessWidget {
  const ThumbnailSizeSegmented({
    super.key,
    required this.thumbnailSize,
    required this.onChanged,
  });

  final ThumbnailSize thumbnailSize;
  final ValueChanged<ThumbnailSize> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: ThumbnailSize.values
            .map(
              (size) => SegButton(
                label: size.label,
                selected: size == thumbnailSize,
                onTap: () => onChanged(size),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}
