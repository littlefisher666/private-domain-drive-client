import 'package:flutter/material.dart';

import '../../domain/file_item.dart';
import 'seg_button.dart';

/// 浏览模式（列表/缩略图）分段切换控件。
class CupertinoSegmented extends StatelessWidget {
  const CupertinoSegmented({
    super.key,
    required this.browseMode,
    required this.onChanged,
  });

  final BrowseMode browseMode;
  final ValueChanged<BrowseMode> onChanged;

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
        children: <Widget>[
          SegButton(
            label: '列表',
            selected: browseMode == BrowseMode.list,
            onTap: () => onChanged(BrowseMode.list),
          ),
          SegButton(
            label: '缩略图',
            selected: browseMode == BrowseMode.grid,
            onTap: () => onChanged(BrowseMode.grid),
          ),
        ],
      ),
    );
  }
}
