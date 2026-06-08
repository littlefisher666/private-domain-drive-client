import 'package:flutter/material.dart';

import '../../../app/router/route_names.dart';
import '../../../core/utils/file_size_formatter.dart';
import '../application/load_directory_use_case.dart';
import '../domain/file_item.dart';
import '../infrastructure/file_repository.dart';
import '../../preview/presentation/preview_page.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key});

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  static const _rootPath = 'shared/';

  late final LoadDirectoryUseCase _loadDirectoryUseCase;
  late Future<List<FileItem>> _itemsFuture;
  String _currentPath = _rootPath;

  @override
  void initState() {
    super.initState();
    _loadDirectoryUseCase = const LoadDirectoryUseCase(StaticFileRepository());
    _itemsFuture = _loadDirectoryUseCase.execute(_currentPath);
  }

  Future<void> _reload() async {
    final future = _loadDirectoryUseCase.execute(_currentPath);
    setState(() {
      _itemsFuture = future;
    });
    await future;
  }

  Future<void> _openDirectory(String path) async {
    final future = _loadDirectoryUseCase.execute(path);
    setState(() {
      _currentPath = path;
      _itemsFuture = future;
    });
    await future;
  }

  Future<void> _goToParentDirectory() async {
    if (_currentPath == _rootPath) {
      return;
    }

    final normalized = _currentPath.endsWith('/')
        ? _currentPath.substring(0, _currentPath.length - 1)
        : _currentPath;
    final lastSlash = normalized.lastIndexOf('/');
    final parent = lastSlash <= 0 ? _rootPath : '${normalized.substring(0, lastSlash + 1)}';
    await _openDirectory(parent);
  }

  void _openPreview(FileItem item) {
    Navigator.of(context).pushNamed(
      RouteNames.preview,
      arguments: PreviewPageArguments(fileName: item.name, filePath: item.path),
    );
  }

  void _openTransfers() {
    Navigator.of(context).pushNamed(RouteNames.transfers);
  }

  void _openSettings() {
    Navigator.of(context).pushNamed(RouteNames.settings);
  }

  void _logout() {
    Navigator.of(context).pushNamedAndRemoveUntil(RouteNames.login, (route) => false);
  }

  String _buildSubtitle(FileItem item) {
    final parts = <String>[];

    parts.add(item.isDirectory ? '文件夹' : FileSizeFormatter.format(item.size ?? 0));

    if (item.updatedAt != null) {
      final updatedAt = item.updatedAt!;
      final month = updatedAt.month.toString().padLeft(2, '0');
      final day = updatedAt.day.toString().padLeft(2, '0');
      final hour = updatedAt.hour.toString().padLeft(2, '0');
      final minute = updatedAt.minute.toString().padLeft(2, '0');
      parts.add('${updatedAt.year}-$month-$day $hour:$minute');
    }

    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('共享空间'),
        actions: <Widget>[
          IconButton(
            onPressed: _openTransfers,
            icon: const Icon(Icons.swap_vert_circle_outlined),
            tooltip: '传输任务',
          ),
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openTransfers,
        icon: const Icon(Icons.cloud_upload_outlined),
        label: const Text('上传'),
      ),
      body: FutureBuilder<List<FileItem>>(
        future: _itemsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Text('目录加载失败'),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _reload,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            );
          }

          final items = snapshot.data ?? const <FileItem>[];
          final content = items.isEmpty
              ? ListView(
                  children: const <Widget>[
                    SizedBox(height: 200),
                    Center(child: Text('当前目录为空')),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      leading: Icon(
                        item.isDirectory ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
                      ),
                      title: Text(item.name),
                      subtitle: Text(_buildSubtitle(item)),
                      trailing: item.isDirectory
                          ? const Icon(Icons.chevron_right)
                          : const Icon(Icons.remove_red_eye_outlined),
                      onTap: () {
                        if (item.isDirectory) {
                          _openDirectory(item.path);
                          return;
                        }

                        _openPreview(item);
                      },
                    );
                  },
                );

          return RefreshIndicator(
            onRefresh: _reload,
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              _currentPath,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          if (_currentPath != _rootPath)
                            OutlinedButton.icon(
                              onPressed: _goToParentDirectory,
                              icon: const Icon(Icons.arrow_upward),
                              label: const Text('上一级'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          FilledButton.tonalIcon(
                            onPressed: _openTransfers,
                            icon: const Icon(Icons.upload_file_outlined),
                            label: const Text('上传文件'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _openTransfers,
                            icon: const Icon(Icons.download_outlined),
                            label: const Text('下载任务'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _openSettings,
                            icon: const Icon(Icons.admin_panel_settings_outlined),
                            label: const Text('权限与设置'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _logout,
                            icon: const Icon(Icons.logout),
                            label: const Text('退出登录'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(child: content),
              ],
            ),
          );
        },
      ),
    );
  }
}
