import 'package:flutter/material.dart';

import '../../features/workspace/domain/file_item.dart';

Future<void> showFileSortSheet(
  BuildContext context, {
  required FileSortOption current,
  required ValueChanged<FileSortOption> onSelected,
}) async {
  final option = await showModalBottomSheet<FileSortOption>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '排序方式',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
          ),
          for (final option in FileSortOption.values)
            ListTile(
              dense: true,
              title: Text(option.label),
              trailing:
                  option == current ? const Icon(Icons.check, size: 20) : null,
              onTap: () => Navigator.of(sheetContext).pop(option),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (option != null) onSelected(option);
}
