import 'package:flutter/material.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/cupertino_desktop.dart';
import '../../../core/utils/file_size_formatter.dart';
import '../../../shared/state/app_controller.dart';
import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/file_icon.dart';
import '../../preview/presentation/preview_page.dart';
import '../domain/file_item.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key, this.desktopChrome = false});

  final bool desktopChrome;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  late Future<List<FileItem>> _itemsFuture;
  String? _boundPath;
  int? _boundTreeRevision;

  bool get _desktop =>
      widget.desktopChrome || MediaQuery.sizeOf(context).width >= 960;

  void _syncDirectoryBinding(AppController controller, {bool force = false}) {
    if (!force &&
        _boundPath == controller.currentPath &&
        _boundTreeRevision == controller.treeRevision) {
      return;
    }
    _boundPath = controller.currentPath;
    _boundTreeRevision = controller.treeRevision;
    _itemsFuture = controller.listDirectory(controller.currentPath);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncDirectoryBinding(AppScope.of(context));
  }

  Future<void> _reload() async {
    final controller = AppScope.of(context);
    final future = controller.listDirectory(controller.currentPath);
    setState(() {
      _itemsFuture = future;
      _boundPath = controller.currentPath;
      _boundTreeRevision = controller.treeRevision;
    });
    await future;
  }

  void _ensureDefaultSelection(List<FileItem> items) {
    if (items.isEmpty) {
      return;
    }
    final controller = AppScope.read(context);
    final selected = controller.selectedItem;
    final stillVisible =
        selected != null && items.any((item) => item.path == selected.path);
    if (stillVisible) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final current = AppScope.read(context).selectedItem;
      final missing =
          current == null || !items.any((item) => item.path == current.path);
      if (missing) {
        AppScope.read(context).selectItem(items.first);
      }
    });
  }

  Widget _buildItemsArea({
    required AppController controller,
    required bool desktop,
    required bool canUpload,
  }) {
    return FutureBuilder<List<FileItem>>(
      future: _itemsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text('目录加载失败'),
                const SizedBox(height: 12),
                FilledButton(onPressed: _reload, child: const Text('重试')),
              ],
            ),
          );
        }

        final items = snapshot.data ?? const <FileItem>[];
        if (desktop) {
          _ensureDefaultSelection(items);
        }

        if (items.isEmpty) {
          return _EmptyState(
            canUpload: canUpload,
            onAction: canUpload
                ? (desktop ? () => _mockUpload(fromAlbum: false) : _showUploadSheet)
                : null,
          );
        }

        return ValueListenableBuilder<FileItem?>(
          valueListenable: controller.selectedItemListenable,
          builder: (context, selected, _) {
            final selectedPath = selected?.path;
            if (controller.browseMode == BrowseMode.grid) {
              return _GridView(
                items: items,
                selectedPath: selectedPath,
                desktop: desktop,
                subtitleBuilder: _subtitle,
                onOpen: _handleOpen,
                onMore: desktop ? (_) {} : _showItemActions,
                onSelect: _handleSelect,
                canUpload: canUpload,
                canDelete: controller.capabilities.delete,
                canDownload: controller.capabilities.download,
                onDownload: _download,
                onRename: _rename,
                onDelete: _delete,
              );
            }
            return _ListView(
              items: items,
              desktop: desktop,
              selectedPath: selectedPath,
              subtitleBuilder: _subtitle,
              metaTimeBuilder: _metaTime,
              canUpload: canUpload,
              canDelete: controller.capabilities.delete,
              canDownload: controller.capabilities.download,
              onOpen: _handleOpen,
              onMore: desktop ? (_) {} : _showItemActions,
              onSelect: _handleSelect,
              onPreview: _openPreview,
              onDownload: _download,
              onRename: _rename,
              onDelete: _delete,
            );
          },
        );
      },
    );
  }

  Future<void> _openDirectory(String path) async {
    final controller = AppScope.of(context);
    controller.setCurrentPath(path);
    await _reload();
  }

  Future<void> _goUp() async {
    final controller = AppScope.of(context);
    if (controller.currentPath == AppController.rootPrefix) {
      return;
    }
    await _openDirectory(controller.parentPath(controller.currentPath));
  }

  void _openPreview(FileItem item) {
    Navigator.of(context).pushNamed(
      RouteNames.preview,
      arguments: PreviewPageArguments(fileName: item.name, filePath: item.path),
    );
  }

  Future<void> _handleOpen(FileItem item) async {
    final controller = AppScope.of(context);
    controller.selectItem(item);
    if (item.isDirectory) {
      await _openDirectory(item.path);
      return;
    }
    _openPreview(item);
  }

  void _handleSelect(FileItem item) {
    AppScope.read(context).selectItem(item);
  }

  Future<void> _createFolder() async {
    final controller = AppScope.of(context);
    if (!controller.capabilities.upload) {
      AppFeedback.showSnack(context, '当前身份没有新建权限');
      return;
    }
    final name = await AppFeedback.promptText(
      context,
      title: '新建文件夹',
      hintText: '请输入文件夹名称',
      confirmLabel: '创建',
    );
    if (name == null) {
      return;
    }
    try {
      await controller.createFolder(name);
      await _reload();
      if (mounted) {
        AppFeedback.showSnack(context, '已创建 $name');
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _rename(FileItem item) async {
    final controller = AppScope.of(context);
    if (!controller.capabilities.upload && !controller.capabilities.delete) {
      AppFeedback.showSnack(context, '当前身份没有重命名权限');
      return;
    }
    final name = await AppFeedback.promptText(
      context,
      title: '重命名',
      initialValue: item.name,
      confirmLabel: '保存',
    );
    if (name == null || name == item.name) {
      return;
    }
    try {
      await controller.renameItem(item, name);
      await _reload();
      if (mounted) {
        AppFeedback.showSnack(context, '已重命名为 $name');
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _delete(FileItem item) async {
    final controller = AppScope.of(context);
    if (!controller.capabilities.delete) {
      AppFeedback.showSnack(context, '当前身份没有删除权限');
      return;
    }
    final confirmed = await AppFeedback.confirm(
      context,
      title: '确认删除？',
      message: '将删除“${item.name}”。一期没有回收站，删除后无法恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) {
      return;
    }
    try {
      await controller.deleteItem(item);
      await _reload();
      if (mounted) {
        AppFeedback.showSnack(context, '已删除 ${item.name}');
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _download(FileItem item) async {
    final controller = AppScope.of(context);
    try {
      await controller.mockDownload(item);
      if (mounted) {
        AppFeedback.showSnack(context, '已开始下载 ${item.name}');
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _mockUpload({required bool fromAlbum}) async {
    final controller = AppScope.of(context);
    if (!controller.capabilities.upload) {
      AppFeedback.showSnack(context, '当前身份没有上传权限');
      return;
    }
    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
    final name = fromAlbum ? 'album-$stamp.jpg' : 'upload-$stamp.bin';
    final size = fromAlbum ? 2 * 1024 * 1024 : 640 * 1024;
    try {
      await controller.mockUpload(fileName: name, size: size);
      await _reload();
      if (mounted) {
        AppFeedback.showSnack(context, '已开始上传 $name');
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _showUploadSheet() async {
    final controller = AppScope.of(context);
    if (!controller.capabilities.upload) {
      AppFeedback.showSnack(context, '当前身份没有上传权限');
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('上传文件'),
                onTap: () {
                  Navigator.pop(context);
                  _mockUpload(fromAlbum: false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_outlined),
                title: const Text('从相册上传'),
                onTap: () {
                  Navigator.pop(context);
                  _mockUpload(fromAlbum: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('新建文件夹'),
                onTap: () {
                  Navigator.pop(context);
                  _createFolder();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showItemActions(FileItem item) async {
    final controller = AppScope.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                title: Text(item.name, style: Theme.of(context).textTheme.titleMedium),
                subtitle: Text(item.path),
              ),
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: Text(item.isDirectory ? '打开' : '打开/预览'),
                onTap: () {
                  Navigator.pop(context);
                  _handleOpen(item);
                },
              ),
              if (!item.isDirectory)
                ListTile(
                  leading: const Icon(Icons.visibility_outlined),
                  title: const Text('预览'),
                  onTap: () {
                    Navigator.pop(context);
                    _openPreview(item);
                  },
                ),
              if (!item.isDirectory && controller.capabilities.download)
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('下载'),
                  onTap: () {
                    Navigator.pop(context);
                    _download(item);
                  },
                ),
              if (controller.capabilities.upload || controller.capabilities.delete)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('重命名'),
                  onTap: () {
                    Navigator.pop(context);
                    _rename(item);
                  },
                ),
              if (controller.capabilities.delete)
                ListTile(
                  leading: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    '删除',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _delete(item);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  String _subtitle(FileItem item) {
    final parts = <String>[item.typeLabel];
    if (!item.isDirectory) {
      parts.add(FileSizeFormatter.format(item.size ?? 0));
    }
    if (item.updatedAt != null) {
      final d = item.updatedAt!;
      final mm = d.month.toString().padLeft(2, '0');
      final dd = d.day.toString().padLeft(2, '0');
      final hh = d.hour.toString().padLeft(2, '0');
      final mi = d.minute.toString().padLeft(2, '0');
      parts.add('${d.year}-$mm-$dd $hh:$mi');
    }
    return parts.join(' · ');
  }

  String _metaTime(FileItem item) {
    if (item.updatedAt == null) {
      return '—';
    }
    final d = item.updatedAt!;
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd $hh:$mi';
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    _syncDirectoryBinding(controller);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final desktop = _desktop;
    final canUpload = controller.capabilities.upload;
    final canDelete = controller.capabilities.delete;
    final canDownload = controller.capabilities.download;

    return Scaffold(
      backgroundColor:
          desktop ? CupertinoDesktopTokens.surface : theme.scaffoldBackgroundColor,
      floatingActionButton: desktop || !canUpload
          ? null
          : FloatingActionButton(
              onPressed: _showUploadSheet,
              child: const Icon(Icons.add),
            ),
      body: SafeArea(
        top: !desktop,
        child: desktop
            ? _DesktopWorkspaceBody(
                path: controller.currentPath,
                canGoUp: controller.currentPath != AppController.rootPrefix,
                canUpload: canUpload,
                canDelete: canDelete,
                canDownload: canDownload,
                browseMode: controller.browseMode,
                selectedListenable: controller.selectedItemListenable,
                listArea: _buildItemsArea(
                  controller: controller,
                  desktop: true,
                  canUpload: canUpload,
                ),
                onGoUp: _goUp,
                onRefresh: _reload,
                onCreateFolder: _createFolder,
                onUpload: () => _mockUpload(fromAlbum: false),
                onBrowseModeChanged: controller.setBrowseMode,
                onOpen: _handleOpen,
                onPreview: _openPreview,
                onDownload: _download,
                onDelete: _delete,
              )
            : Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _MobileHeader(
                      path: controller.currentPath,
                      roleLabel: controller.session?.displayName ?? '成员',
                      canGoUp:
                          controller.currentPath != AppController.rootPrefix,
                      browseMode: controller.browseMode,
                      onGoUp: _goUp,
                      onRefresh: _reload,
                      onBrowseModeChanged: controller.setBrowseMode,
                    ),
                    const SizedBox(height: 12),
                    if (!canUpload || !canDelete)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '当前账号缺少部分文件操作权限。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _buildItemsArea(
                        controller: controller,
                        desktop: false,
                        canUpload: canUpload,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _DesktopWorkspaceBody extends StatelessWidget {
  const _DesktopWorkspaceBody({
    required this.path,
    required this.canGoUp,
    required this.canUpload,
    required this.canDelete,
    required this.canDownload,
    required this.browseMode,
    required this.selectedListenable,
    required this.listArea,
    required this.onGoUp,
    required this.onRefresh,
    required this.onCreateFolder,
    required this.onUpload,
    required this.onBrowseModeChanged,
    required this.onOpen,
    required this.onPreview,
    required this.onDownload,
    required this.onDelete,
  });

  final String path;
  final bool canGoUp;
  final bool canUpload;
  final bool canDelete;
  final bool canDownload;
  final BrowseMode browseMode;
  final ValueNotifier<FileItem?> selectedListenable;
  final Widget listArea;
  final VoidCallback onGoUp;
  final VoidCallback onRefresh;
  final VoidCallback onCreateFolder;
  final VoidCallback onUpload;
  final ValueChanged<BrowseMode> onBrowseModeChanged;
  final ValueChanged<FileItem> onOpen;
  final ValueChanged<FileItem> onPreview;
  final ValueChanged<FileItem> onDownload;
  final ValueChanged<FileItem> onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: const BoxDecoration(
            color: Color(0xE6FFFFFF),
            border: Border(
              bottom: BorderSide(color: CupertinoDesktopTokens.line),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  if (canGoUp) ...<
                    Widget
                  >[
                    OutlinedButton(
                      onPressed: onGoUp,
                      child: const Text('‹ 上级'),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: CupertinoDesktopTokens.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        const Text(
                          '按目录浏览 · 支持列表 / 缩略图 · 拖拽上传',
                          style: TextStyle(
                            fontSize: 12,
                            color: CupertinoDesktopTokens.secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  _CupertinoSegmented(
                    browseMode: browseMode,
                    onChanged: onBrowseModeChanged,
                  ),
                  OutlinedButton(
                    onPressed: onRefresh,
                    child: const Text('刷新'),
                  ),
                  if (canUpload) ...<
                    Widget
                  >[
                    OutlinedButton(
                      onPressed: onCreateFolder,
                      child: const Text('新建文件夹'),
                    ),
                    FilledButton(
                      onPressed: onUpload,
                      child: const Text('上传文件'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: <Widget>[
              Expanded(
                child: Container(
                  color: const Color(0xFFFBFBFD),
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (!canUpload || !canDelete) ...<
                        Widget
                      >[
                        Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: CupertinoDesktopTokens.noteBg,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            '当前账号缺少上传或删除权限。',
                            style: TextStyle(
                              color: CupertinoDesktopTokens.noteFg,
                              fontSize: 12,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                      if (canUpload) ...<
                        Widget
                      >[
                        _DropZone(onTap: onUpload),
                        const SizedBox(height: 12),
                      ],
                      Expanded(child: listArea),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: CupertinoDesktopTokens.previewWidth,
                child: ValueListenableBuilder<FileItem?>(
                  valueListenable: selectedListenable,
                  builder: (context, current, _) {
                    return _DetailPanel(
                      item: current,
                      canDownload: canDownload,
                      canDelete: canDelete,
                      onPreview: current == null || current.isDirectory
                          ? null
                          : () => onPreview(current),
                      onDownload: current == null || current.isDirectory
                          ? null
                          : () => onDownload(current),
                      onOpen: current == null ? null : () => onOpen(current),
                      onDelete: current == null || !canDelete
                          ? null
                          : () => onDelete(current),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CupertinoSegmented extends StatelessWidget {
  const _CupertinoSegmented({
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
        color: CupertinoDesktopTokens.controlFill,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _SegButton(
            label: '列表',
            selected: browseMode == BrowseMode.list,
            onTap: () => onChanged(BrowseMode.list),
          ),
          _SegButton(
            label: '缩略图',
            selected: browseMode == BrowseMode.grid,
            onTap: () => onChanged(BrowseMode.grid),
          ),
        ],
      ),
    );
  }
}

class _SegButton extends StatelessWidget {
  const _SegButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.white : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      elevation: selected ? 1 : 0,
      shadowColor: const Color(0x1F000000),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 28),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: CupertinoDesktopTokens.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileHeader extends StatelessWidget {
  const _MobileHeader({
    required this.path,
    required this.roleLabel,
    required this.canGoUp,
    required this.browseMode,
    required this.onGoUp,
    required this.onRefresh,
    required this.onBrowseModeChanged,
  });

  final String path;
  final String roleLabel;
  final bool canGoUp;
  final BrowseMode browseMode;
  final VoidCallback onGoUp;
  final VoidCallback onRefresh;
  final ValueChanged<BrowseMode> onBrowseModeChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            if (canGoUp)
              IconButton(
                onPressed: onGoUp,
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回上级',
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('共享空间', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 2),
                  Text(
                    '$roleLabel · $path',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
            ),
          ],
        ),
        const SizedBox(height: 10),
        SegmentedButton<BrowseMode>(
          segments: const <ButtonSegment<BrowseMode>>[
            ButtonSegment(
              value: BrowseMode.list,
              label: Text('列表'),
              icon: Icon(Icons.view_list),
            ),
            ButtonSegment(
              value: BrowseMode.grid,
              label: Text('缩略图'),
              icon: Icon(Icons.grid_view),
            ),
          ],
          selected: <BrowseMode>{browseMode},
          onSelectionChanged: (values) => onBrowseModeChanged(values.first),
        ),
      ],
    );
  }
}

class _DropZone extends StatelessWidget {
  const _DropZone({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: CupertinoDesktopTokens.blue.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: CupertinoDesktopTokens.blue.withValues(alpha: 0.35),
              width: 1.5,
            ),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '拖拽文件到这里上传',
                style: TextStyle(
                  color: CupertinoDesktopTokens.blue,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'macOS 支持拖拽上传；也可点击选择文件。大文件将走分片上传。',
                style: TextStyle(
                  fontSize: 12,
                  color: CupertinoDesktopTokens.secondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.canUpload, this.onAction});

  final bool canUpload;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: CupertinoDesktopTokens.line,
          style: BorderStyle.solid,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            '当前目录为空',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: CupertinoDesktopTokens.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            canUpload ? '可以新建文件夹或上传文件。' : '当前目录暂无内容。',
            style: const TextStyle(
              fontSize: 13,
              height: 1.55,
              color: CupertinoDesktopTokens.secondary,
            ),
          ),
          if (canUpload && onAction != null) ...<
            Widget
          >[
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: const Text('上传或新建')),
          ],
        ],
      ),
    );
  }
}

class _GhostAction extends StatelessWidget {
  const _GhostAction({
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor:
            danger ? CupertinoDesktopTokens.danger : CupertinoDesktopTokens.blue,
        minimumSize: const Size(0, 26),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}

class _ListView extends StatelessWidget {
  const _ListView({
    required this.items,
    required this.desktop,
    required this.selectedPath,
    required this.subtitleBuilder,
    required this.metaTimeBuilder,
    required this.canUpload,
    required this.canDelete,
    required this.canDownload,
    required this.onOpen,
    required this.onMore,
    required this.onSelect,
    required this.onPreview,
    required this.onDownload,
    required this.onRename,
    required this.onDelete,
  });

  final List<FileItem> items;
  final bool desktop;
  final String? selectedPath;
  final String Function(FileItem) subtitleBuilder;
  final String Function(FileItem) metaTimeBuilder;
  final bool canUpload;
  final bool canDelete;
  final bool canDownload;
  final ValueChanged<FileItem> onOpen;
  final ValueChanged<FileItem> onMore;
  final ValueChanged<FileItem> onSelect;
  final ValueChanged<FileItem> onPreview;
  final ValueChanged<FileItem> onDownload;
  final ValueChanged<FileItem> onRename;
  final ValueChanged<FileItem> onDelete;

  @override
  Widget build(BuildContext context) {
    if (!desktop) {
      return Card(
        clipBehavior: Clip.antiAlias,
        child: ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = items[index];
            return ListTile(
              leading: FileTypeIcon(item: item),
              title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                subtitleBuilder(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                onSelect(item);
                onOpen(item);
              },
              onLongPress: () => onMore(item),
              trailing: IconButton(
                tooltip: '更多',
                onPressed: () => onMore(item),
                icon: const Icon(Icons.more_vert),
              ),
            );
          },
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CupertinoDesktopTokens.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(
          height: 1,
          color: Color(0x1F3C3C43),
        ),
        itemBuilder: (context, index) {
          final item = items[index];
          final selected = item.path == selectedPath;
          return Material(
            color: selected
                ? CupertinoDesktopTokens.blue.withValues(alpha: 0.12)
                : Colors.transparent,
            child: InkWell(
              onTap: () => onSelect(item),
              onDoubleTap: () => onOpen(item),
              hoverColor: CupertinoDesktopTokens.blue.withValues(alpha: 0.04),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                child: Row(
                  children: <Widget>[
                    FileTypeBadge(item: item),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: CupertinoDesktopTokens.ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item.isDirectory
                                ? item.typeLabel
                                : '${item.typeLabel} · ${FileSizeFormatter.format(item.size ?? 0)}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: CupertinoDesktopTokens.secondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Text(
                          metaTimeBuilder(item),
                          style: const TextStyle(
                            fontSize: 12,
                            color: CupertinoDesktopTokens.secondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (item.isDirectory)
                              _GhostAction(
                                label: '打开',
                                onPressed: () => onOpen(item),
                              )
                            else ...<
                              Widget
                            >[
                              if (canDownload)
                                _GhostAction(
                                  label: '下载',
                                  onPressed: () => onDownload(item),
                                ),
                              if (canUpload || canDelete)
                                _GhostAction(
                                  label: '重命名',
                                  onPressed: () => onRename(item),
                                ),
                              if (canDelete)
                                _GhostAction(
                                  label: '删除',
                                  danger: true,
                                  onPressed: () => onDelete(item),
                                ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GridView extends StatelessWidget {
  const _GridView({
    required this.items,
    required this.selectedPath,
    required this.desktop,
    required this.subtitleBuilder,
    required this.onOpen,
    required this.onMore,
    required this.onSelect,
    required this.canUpload,
    required this.canDelete,
    required this.canDownload,
    required this.onDownload,
    required this.onRename,
    required this.onDelete,
  });

  final List<FileItem> items;
  final String? selectedPath;
  final bool desktop;
  final String Function(FileItem) subtitleBuilder;
  final ValueChanged<FileItem> onOpen;
  final ValueChanged<FileItem> onMore;
  final ValueChanged<FileItem> onSelect;
  final bool canUpload;
  final bool canDelete;
  final bool canDownload;
  final ValueChanged<FileItem> onDownload;
  final ValueChanged<FileItem> onRename;
  final ValueChanged<FileItem> onDelete;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: desktop ? 150 : 180,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: desktop ? 0.78 : 0.86,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final selected = item.path == selectedPath;
        final scheme = Theme.of(context).colorScheme;

        if (!desktop) {
          return Material(
            color: selected ? scheme.primary.withValues(alpha: 0.08) : scheme.surface,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () {
                onSelect(item);
                onOpen(item);
              },
              onLongPress: () => onMore(item),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: selected ? scheme.primary : scheme.outlineVariant,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: scheme.surfaceContainerHighest,
                        ),
                        child: Center(child: FileTypeIcon(item: item, size: 36)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.typeLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => onSelect(item),
            onDoubleTap: () => onOpen(item),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: selected
                      ? CupertinoDesktopTokens.blue.withValues(alpha: 0.35)
                      : CupertinoDesktopTokens.line,
                ),
                boxShadow: selected
                    ? const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x14007AFF),
                          blurRadius: 18,
                          offset: Offset(0, 8),
                        ),
                      ]
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: FileTypeThumb(item: item)),
                  const SizedBox(height: 10),
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: CupertinoDesktopTokens.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.isDirectory
                        ? '文件夹'
                        : '${item.typeLabel} · ${FileSizeFormatter.format(item.size ?? 0)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: CupertinoDesktopTokens.secondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (item.isDirectory)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _GhostAction(
                        label: '打开',
                        onPressed: () => onOpen(item),
                      ),
                    )
                  else
                    Wrap(
                      children: <Widget>[
                        if (canDownload)
                          _GhostAction(
                            label: '下载',
                            onPressed: () => onDownload(item),
                          ),
                        if (canUpload || canDelete)
                          _GhostAction(
                            label: '重命名',
                            onPressed: () => onRename(item),
                          ),
                        if (canDelete)
                          _GhostAction(
                            label: '删除',
                            danger: true,
                            onPressed: () => onDelete(item),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({
    required this.item,
    required this.canDownload,
    required this.canDelete,
    this.onPreview,
    this.onDownload,
    this.onOpen,
    this.onDelete,
  });

  final FileItem? item;
  final bool canDownload;
  final bool canDelete;
  final VoidCallback? onPreview;
  final VoidCallback? onDownload;
  final VoidCallback? onOpen;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: CupertinoDesktopTokens.previewBg,
        border: Border(
          left: BorderSide(color: CupertinoDesktopTokens.line),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: CupertinoDesktopTokens.line),
              ),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '详情预览',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: CupertinoDesktopTokens.ink,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '选中文件后展示基础信息',
                  style: TextStyle(
                    fontSize: 12,
                    color: CupertinoDesktopTokens.secondary,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: item == null
                ? const Center(
                    child: Text(
                      '选中文件后展示详情',
                      style: TextStyle(
                        color: CupertinoDesktopTokens.secondary,
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
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: CupertinoDesktopTokens.ink,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _kv('类型', item!.typeLabel),
                      _kv(
                        '大小',
                        item!.isDirectory
                            ? '—'
                            : FileSizeFormatter.format(item!.size ?? 0),
                      ),
                      _kv('路径', item!.path),
                      _kv(
                        '更新',
                        item!.updatedAt == null
                            ? '—'
                            : _formatTime(item!.updatedAt!),
                      ),
                      _kv(
                        '能力',
                        [
                          if (canDownload) '可下载',
                          if (canDelete) '可删除',
                          if (!canDownload && !canDelete) '只读',
                        ].join(' / '),
                      ),
                      const SizedBox(height: 16),
                      if (canDownload && onDownload != null && !item!.isDirectory)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: SizedBox(
                            width: double.infinity,
                            height: 36,
                            child: FilledButton(
                              onPressed: onDownload,
                              child: const Text('下载'),
                            ),
                          ),
                        ),
                      if (onOpen != null || onPreview != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: SizedBox(
                            width: double.infinity,
                            height: 36,
                            child: OutlinedButton(
                              onPressed: item!.isDirectory ? onOpen : (onPreview ?? onOpen),
                              child: Text(item!.isDirectory ? '打开' : '预览 / 打开'),
                            ),
                          ),
                        ),
                      if (canDelete && onDelete != null)
                        SizedBox(
                          width: double.infinity,
                          height: 36,
                          child: OutlinedButton(
                            onPressed: onDelete,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: CupertinoDesktopTokens.danger,
                              backgroundColor:
                                  CupertinoDesktopTokens.danger.withValues(alpha: 0.12),
                            ),
                            child: const Text('删除'),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: CupertinoDesktopTokens.secondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: CupertinoDesktopTokens.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd $hh:$mi';
  }
}
