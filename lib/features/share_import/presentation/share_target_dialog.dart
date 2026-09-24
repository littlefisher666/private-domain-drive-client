import 'package:flutter/material.dart';

import '../../../shared/state/app_scope.dart';
import '../../workspace/domain/file_item.dart';

/// 分享导入时直接弹出的上传目标目录选择弹窗。
///
/// 浏览远端目录并选中后返回目录路径；取消返回 null。
class ShareTargetDialog extends StatefulWidget {
  const ShareTargetDialog({super.key, required this.initialPath});

  /// 初始定位的目录，默认从根目录开始。
  final String initialPath;

  @override
  State<ShareTargetDialog> createState() => _ShareTargetDialogState();
}

class _ShareTargetDialogState extends State<ShareTargetDialog> {
  late String _currentPath;
  List<FileItem> _directories = const <FileItem>[];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath;
    _loadDirectories();
  }

  Future<void> _loadDirectories() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final controller = AppScope.read(context);
    try {
      final items = await controller.listDirectory(_currentPath);
      if (!mounted) return;
      setState(() {
        _directories = items.where((item) => item.isDirectory).toList(
              growable: false,
            );
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  bool get _canGoUp {
    final controller = AppScope.read(context);
    return controller.parentPath(_currentPath) != _currentPath;
  }

  void _enterDirectory(FileItem directory) {
    setState(() => _currentPath = directory.path);
    _loadDirectories();
  }

  void _goUp() {
    if (!_canGoUp) return;
    setState(
      () => _currentPath = AppScope.read(context).parentPath(_currentPath),
    );
    _loadDirectories();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.read(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('选择上传目录'),
      content: SizedBox(
        width: 320,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                IconButton(
                  tooltip: '上一级',
                  onPressed: _canGoUp ? _goUp : null,
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: Text(
                    controller.displayPath(_currentPath),
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(child: _buildBody(theme)),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_currentPath),
          child: const Text('上传到此处'),
        ),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('目录加载失败'),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _loadDirectories, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_directories.isEmpty) {
      return Center(
        child: Text(
          '没有子目录',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      itemCount: _directories.length,
      itemBuilder: (context, index) {
        final directory = _directories[index];
        return ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(directory.name),
          onTap: () => _enterDirectory(directory),
        );
      },
    );
  }
}
