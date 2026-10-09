import 'package:flutter/material.dart';

import '../../../../shared/state/app_controller.dart';

/// 目录选择对话框：面包屑 + 目录列表导航，用于选定移动目标（含根目录）。
Future<String?> showDirectoryPickerDialog(
  BuildContext context, {
  required AppController controller,
  Set<String> invalidPrefixes = const <String>{},
  String title = '选择目标目录',
  String confirmLabel = '移动到此处',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _DirectoryPickerDialog(
      controller: controller,
      invalidPrefixes: invalidPrefixes,
      title: title,
      confirmLabel: confirmLabel,
    ),
  );
}

class _DirectoryPickerDialog extends StatefulWidget {
  const _DirectoryPickerDialog({
    required this.controller,
    required this.invalidPrefixes,
    required this.title,
    required this.confirmLabel,
  });

  final AppController controller;
  final Set<String> invalidPrefixes;
  final String title;
  final String confirmLabel;

  @override
  State<_DirectoryPickerDialog> createState() => _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState extends State<_DirectoryPickerDialog> {
  late String _path = widget.controller.currentPath;
  late Future<List<_DirectoryOption>> _future = _load(_path);

  Future<List<_DirectoryOption>> _load(String path) async {
    final items = await widget.controller.listDirectory(path);
    final directories = items.where((item) => item.isDirectory).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return directories
        .map((item) => _DirectoryOption(
              path: item.path,
              name: item.name,
              disabled: widget.invalidPrefixes.contains(item.path) ||
                  widget.invalidPrefixes
                      .any((prefix) => item.path.startsWith(prefix)),
            ))
        .toList(growable: false);
  }

  void _enter(String path) {
    setState(() {
      _path = path;
      _future = _load(path);
    });
  }

  void _goUp() {
    _enter(widget.controller.parentPath(_path));
  }

  bool get _canConfirm =>
      !widget.controller.isMoving && !widget.invalidPrefixes.contains(_path);

  List<(String, String)> get _breadcrumbs {
    final root = widget.controller.currentPath;
    final segments = <(String, String)>[
      (widget.controller.displayPath(root), root),
    ];
    if (_path.length > root.length) {
      final relative = _path.substring(root.length);
      var accumulated = root;
      for (final segment in relative.split('/')) {
        if (segment.isEmpty) continue;
        accumulated = '$accumulated$segment/';
        segments.add((segment, accumulated));
      }
    }
    return segments;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 4,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (var index = 0; index < _breadcrumbs.length; index++) ...[
                  if (index > 0)
                    Icon(Icons.chevron_right,
                        size: 16, color: scheme.onSurfaceVariant),
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => _enter(_breadcrumbs[index].$2),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      child: Text(
                        _breadcrumbs[index].$1,
                        style: TextStyle(
                          fontSize: 13,
                          color: index == _breadcrumbs.length - 1
                              ? scheme.onSurface
                              : scheme.primary,
                          fontWeight: index == _breadcrumbs.length - 1
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (_path != widget.controller.currentPath)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _goUp,
                  icon: const Icon(Icons.arrow_upward, size: 16),
                  label: const Text('上一级'),
                ),
              ),
            Expanded(
              child: FutureBuilder<List<_DirectoryOption>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        '目录加载失败',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    );
                  }
                  final options = snapshot.data ?? const <_DirectoryOption>[];
                  if (options.isEmpty) {
                    return Center(
                      child: Text(
                        '此目录下没有子文件夹',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: options.length,
                    itemBuilder: (context, index) {
                      final option = options[index];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.folder_outlined,
                          size: 20,
                          color: option.disabled
                              ? scheme.onSurfaceVariant
                              : scheme.primary,
                        ),
                        title: Text(
                          option.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: option.disabled
                                ? scheme.onSurfaceVariant
                                : scheme.onSurface,
                          ),
                        ),
                        enabled: !option.disabled,
                        onTap: () => _enter(option.path),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _canConfirm
              ? () => Navigator.of(context).pop(_path)
              : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _DirectoryOption {
  const _DirectoryOption({
    required this.path,
    required this.name,
    required this.disabled,
  });

  final String path;
  final String name;
  final bool disabled;
}
