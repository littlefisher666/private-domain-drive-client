import 'package:flutter/material.dart';

import '../../../../shared/state/app_controller.dart';
import '../domain/file_item.dart';

/// 创建链接对话框：名称输入与挂载层级选择合并在同一弹窗内完成，
/// 校验失败时就地提示并保持弹窗打开。
Future<bool> showCreateAliasDialog(
  BuildContext context, {
  required AppController controller,
  required FileItem folder,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _CreateAliasDialog(
      controller: controller,
      folder: folder,
    ),
  ).then((value) => value ?? false);
}

class _CreateAliasDialog extends StatefulWidget {
  const _CreateAliasDialog({
    required this.controller,
    required this.folder,
  });

  final AppController controller;
  final FileItem folder;

  @override
  State<_CreateAliasDialog> createState() => _CreateAliasDialogState();
}

class _CreateAliasDialogState extends State<_CreateAliasDialog> {
  late final TextEditingController _nameController =
      TextEditingController(text: widget.folder.name);
  late String _path = widget.controller.currentPath;
  late Future<List<_DirectoryOption>> _future = _load(_path);
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<List<_DirectoryOption>> _load(String path) async {
    // 与目录选择器一致：只做轻量前缀列举，避免逐目录统计拖慢导航。
    final directories = await widget.controller.listPickerDirectories(path);
    return directories
        .map((item) => _DirectoryOption(
              path: item.path,
              name: item.name,
              isAlias: item.isAlias,
              disabled: item.path.startsWith(widget.folder.path),
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
      !_submitting && _nameController.text.trim().isNotEmpty;

  List<(String, String)> get _breadcrumbs {
    final root = widget.controller.workspaceRoot;
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

  Future<void> _confirm() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _submitting) {
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.controller.createAlias(
        widget.folder,
        name,
        parentPrefix: _path,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('创建链接「${widget.folder.name}」'),
      content: SizedBox(
        width: 420,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _nameController,
              autofocus: true,
              enabled: !_submitting,
              decoration: InputDecoration(
                labelText: '链接名称',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _confirm(),
            ),
            const SizedBox(height: 12),
            Text(
              '链接位置',
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
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
                    onTap: _submitting
                        ? null
                        : () => _enter(_breadcrumbs[index].$2),
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
            if (_path != widget.controller.workspaceRoot)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _submitting ? null : _goUp,
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
                        leading: option.isAlias
                            ? Icon(
                                Icons.link,
                                size: 20,
                                color: option.disabled
                                    ? scheme.onSurfaceVariant
                                    : scheme.primary,
                              )
                            : Icon(
                                Icons.folder_outlined,
                                size: 20,
                                color: option.disabled
                                    ? scheme.onSurfaceVariant
                                    : scheme.primary,
                              ),
                        title: Text(
                          option.isAlias
                              ? '${option.name}（链接）'
                              : option.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: option.disabled
                                ? scheme.onSurfaceVariant
                                : scheme.onSurface,
                          ),
                        ),
                        enabled: !option.disabled && !_submitting,
                        onTap: () => _enter(option.path),
                      );
                    },
                  );
                },
              ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: scheme.error, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _canConfirm ? _confirm : null,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('创建'),
        ),
      ],
    );
  }
}

class _DirectoryOption {
  const _DirectoryOption({
    required this.path,
    required this.name,
    required this.isAlias,
    required this.disabled,
  });

  final String path;
  final String name;
  final bool isAlias;
  final bool disabled;
}
