import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// 打开系统文件选择器并将选中文件上传到当前目录。
///
/// 该入口同时供桌面标题栏和目录页按钮使用，确保两个按钮行为一致。
Future<void> pickAndUploadFile(
  BuildContext context, {
  bool fromAlbum = false,
}) async {
  final controller = AppScope.read(context);
  if (!controller.capabilities.upload) {
    AppFeedback.showSnack(context, '当前身份没有上传权限');
    return;
  }

  try {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: fromAlbum ? FileType.image : FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final picked = result.files.single;
    final bytes = picked.bytes ??
        (picked.path == null ? null : await File(picked.path!).readAsBytes());
    if (bytes == null) {
      throw StateError('无法读取所选文件');
    }
    await controller.uploadBytes(fileName: picked.name, bytes: bytes);
    if (context.mounted) {
      AppFeedback.showSnack(context, '已上传 ${picked.name}');
    }
  } catch (error) {
    if (context.mounted) {
      AppFeedback.showSnack(
        context,
        error.toString().replaceFirst('Bad state: ', ''),
      );
    }
  }
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
                const SizedBox(height: 8),
                Text(
                  '详细信息已写入调试日志',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13),
                ),
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
                ? (desktop
                    ? () => _pickUpload(fromAlbum: false)
                    : _showUploadSheet)
                : null,
          );
        }

        return Focus(
          autofocus: desktop,
          onKeyEvent: (_, event) {
            if (desktop &&
                event is KeyDownEvent &&
                HardwareKeyboard.instance.isMetaPressed &&
                event.logicalKey == LogicalKeyboardKey.keyA) {
              controller.selectAllItems(items);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ValueListenableBuilder<Set<String>>(
            valueListenable: controller.multiSelectedPathsListenable,
            builder: (context, selectedPaths, _) {
              final selectedItems = items
                  .where((item) => selectedPaths.contains(item.path))
                  .toList(growable: false);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _BatchSelectionBar(
                    selecting: controller.isMultiSelectionMode,
                    selectedCount: selectedItems.length,
                    allSelected: selectedItems.length == items.length,
                    canDownload: controller.capabilities.download,
                    canDelete: controller.capabilities.delete,
                    onEnter: controller.enterMultiSelection,
                    onSelectAll: () => controller.selectAllItems(items),
                    onCancel: controller.clearMultiSelection,
                    onDownload: selectedItems.isEmpty
                        ? null
                        : () => _downloadSelected(selectedItems),
                    onDelete: selectedItems.isEmpty
                        ? null
                        : () => _deleteSelected(selectedItems),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ValueListenableBuilder<FileItem?>(
                      valueListenable: controller.selectedItemListenable,
                      builder: (context, selected, _) {
                        final selectedPath = selected?.path;
                        final onSelect = controller.isMultiSelectionMode
                            ? (FileItem item) => _toggleMultiSelection(item, items)
                            : _handleSelect;
                        if (controller.browseMode == BrowseMode.grid) {
                          return _GridView(
                            items: items,
                            selectedPath: selectedPath,
                            selectedPaths: selectedPaths,
                            multiSelecting: controller.isMultiSelectionMode,
                            desktop: desktop,
                            subtitleBuilder: _subtitle,
                            onOpen: _handleOpen,
                            onMore: desktop ? (_) {} : _showItemActions,
                            onSelect: onSelect,
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
                          selectedPaths: selectedPaths,
                          multiSelecting: controller.isMultiSelectionMode,
                          subtitleBuilder: _subtitle,
                          metaTimeBuilder: _metaTime,
                          canUpload: canUpload,
                          canDelete: controller.capabilities.delete,
                          canDownload: controller.capabilities.download,
                          onOpen: _handleOpen,
                          onMore: desktop ? (_) {} : _showItemActions,
                          onSelect: onSelect,
                          onPreview: _openPreview,
                          onDownload: _download,
                          onRename: _rename,
                          onDelete: _delete,
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
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

  void _toggleMultiSelection(FileItem item, List<FileItem> items) {
    AppScope.read(context).toggleMultiSelection(
      item,
      visibleItems: items,
      range: HardwareKeyboard.instance.isShiftPressed,
    );
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
      final directory = await FilePicker.platform.getDirectoryPath();
      if (directory == null) {
        return;
      }
      controller.enqueueDownload(item, targetDirectory: directory);
      if (mounted) {
        AppFeedback.showSnack(context, '已加入下载队列：${item.name}');
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

  Future<void> _downloadSelected(List<FileItem> items) async {
    final controller = AppScope.of(context);
    final directory = await FilePicker.platform.getDirectoryPath();
    if (directory == null) return;
    if (!mounted) return;
    try {
      final directoryCount = items.where((item) => item.isDirectory).length;
      if (directoryCount > 0) {
        AppFeedback.showSnack(context, '正在展开 $directoryCount 个文件夹…');
      }
      final result = await controller.enqueueDownloadsRecursively(
        items,
        targetDirectory: directory,
      );
      controller.clearMultiSelection();
      if (!mounted) return;
      AppFeedback.showSnack(
        context,
        result.fileCount == 0
            ? '所选文件夹为空，没有可下载文件'
            : '已加入 ${result.fileCount} 个下载任务${result.directoryCount == 0 ? '' : '，已保留文件夹结构'}',
      );
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _deleteSelected(List<FileItem> items) async {
    final controller = AppScope.of(context);
    try {
      final preview = await controller.prepareBatchDelete(items);
      if (!mounted) return;
      final confirmed = await AppFeedback.confirm(
        context,
        title: '确认删除 ${preview.selectedCount} 项？',
        message: '其中包含 ${preview.directoryCount} 个文件夹，共影响 ${preview.objectCount} 个对象。'
            '一期没有回收站，删除后无法恢复。',
        confirmLabel: '删除',
        destructive: true,
      );
      if (!confirmed) return;
      var result = await controller.deleteBatch(preview);
      if (result.failedPaths.isNotEmpty && mounted) {
        final retry = await AppFeedback.confirm(
          context,
          title: '部分删除失败',
          message: '已删除 ${result.deletedPaths.length} 项，${result.failedPaths.length} 项失败。是否重试失败项？',
          confirmLabel: '重试失败项',
        );
        if (retry) {
          final retried = await controller.retryBatchDelete(result.failedPaths);
          result = BatchDeleteSummary(
            deletedPaths: <String>[...result.deletedPaths, ...retried.deletedPaths],
            failedPaths: retried.failedPaths,
          );
        }
      }
      await _reload();
      controller.clearMultiSelection();
      if (mounted) {
        AppFeedback.showSnack(
          context,
          result.failedPaths.isEmpty
              ? '已删除 ${result.deletedPaths.length} 项'
              : '已删除 ${result.deletedPaths.length} 项，${result.failedPaths.length} 项失败',
        );
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(context, error.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  Future<void> _pickUpload({required bool fromAlbum}) async {
    await pickAndUploadFile(context, fromAlbum: fromAlbum);
    if (mounted) await _reload();
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
                  _pickUpload(fromAlbum: false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_outlined),
                title: const Text('从相册上传'),
                onTap: () {
                  Navigator.pop(context);
                  _pickUpload(fromAlbum: true);
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
                title: Text(item.name,
                    style: Theme.of(context).textTheme.titleMedium),
                subtitle: Text(controller.displayPath(item.path)),
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
              if (controller.capabilities.upload ||
                  controller.capabilities.delete)
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
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
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
      backgroundColor: desktop
          ? CupertinoDesktopTokens.surface
          : theme.scaffoldBackgroundColor,
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
                path: controller.displayPath(controller.currentPath),
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
                onUpload: () => _pickUpload(fromAlbum: false),
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
                      path: controller.displayPath(controller.currentPath),
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

class _BatchSelectionBar extends StatelessWidget {
  const _BatchSelectionBar({
    required this.selecting,
    required this.selectedCount,
    required this.allSelected,
    required this.canDownload,
    required this.canDelete,
    required this.onEnter,
    required this.onSelectAll,
    required this.onCancel,
    this.onDownload,
    this.onDelete,
  });

  final bool selecting;
  final int selectedCount;
  final bool allSelected;
  final bool canDownload;
  final bool canDelete;
  final VoidCallback onEnter;
  final VoidCallback onSelectAll;
  final VoidCallback onCancel;
  final VoidCallback? onDownload;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    if (!selecting) {
      return Align(
        alignment: Alignment.centerRight,
        child: FilledButton.tonalIcon(
          onPressed: onEnter,
          icon: const Icon(Icons.checklist_outlined),
          label: const Text('选择'),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    const compactButtonStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(Size(0, 32)),
      padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '已选 $selectedCount 项',
              style: TextStyle(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onSelectAll,
            style: compactButtonStyle,
            icon: Icon(allSelected ? Icons.select_all : Icons.done_all),
            label: Text(allSelected ? '重新全选' : '全选'),
          ),
          if (canDownload)
            FilledButton.icon(
              onPressed: onDownload,
              style: compactButtonStyle,
              icon: const Icon(Icons.download_outlined),
              label: const Text('下载'),
            ),
          if (canDelete)
            TextButton.icon(
              onPressed: onDelete,
              style: compactButtonStyle.copyWith(
                foregroundColor: WidgetStatePropertyAll<Color>(scheme.error),
              ),
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除'),
            ),
          TextButton.icon(
            onPressed: onCancel,
            style: compactButtonStyle,
            icon: const Icon(Icons.close),
            label: const Text('退出选择'),
          ),
        ],
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
                  if (canGoUp) ...<Widget>[
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
                  if (canUpload) ...<Widget>[
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
                      if (!canUpload || !canDelete) ...<Widget>[
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
          if (canUpload && onAction != null) ...<Widget>[
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
        foregroundColor: danger
            ? CupertinoDesktopTokens.danger
            : CupertinoDesktopTokens.blue,
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
    required this.selectedPaths,
    required this.multiSelecting,
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
  final Set<String> selectedPaths;
  final bool multiSelecting;
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
              leading: multiSelecting
                  ? Checkbox(
                      value: selectedPaths.contains(item.path),
                      onChanged: (_) => onSelect(item),
                    )
                  : FileTypeIcon(item: item),
              title:
                  Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                subtitleBuilder(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                onSelect(item);
                if (!multiSelecting) onOpen(item);
              },
              onLongPress: () => onSelect(item),
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
          final selected = multiSelecting
              ? selectedPaths.contains(item.path)
              : item.path == selectedPath;
          return Material(
            color: selected
                ? CupertinoDesktopTokens.blue.withValues(alpha: 0.12)
                : Colors.transparent,
            child: InkWell(
              onTap: () => onSelect(item),
              onDoubleTap: multiSelecting ? null : () => onOpen(item),
              hoverColor: CupertinoDesktopTokens.blue.withValues(alpha: 0.04),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                child: Row(
                  children: <Widget>[
                    if (multiSelecting) ...<Widget>[
                      Checkbox(
                        value: selected,
                        onChanged: (_) => onSelect(item),
                      ),
                      const SizedBox(width: 6),
                    ],
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
                            if (multiSelecting)
                              const SizedBox.shrink()
                            else if (item.isDirectory)
                              _GhostAction(
                                label: '打开',
                                onPressed: () => onOpen(item),
                              )
                            else ...<Widget>[
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
    required this.selectedPaths,
    required this.multiSelecting,
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
  final Set<String> selectedPaths;
  final bool multiSelecting;
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
        final selected = multiSelecting
            ? selectedPaths.contains(item.path)
            : item.path == selectedPath;
        final scheme = Theme.of(context).colorScheme;

        if (!desktop) {
          return Material(
            color: selected
                ? scheme.primary.withValues(alpha: 0.08)
                : scheme.surface,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () {
                onSelect(item);
                if (!multiSelecting) onOpen(item);
              },
              onLongPress: () => onSelect(item),
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
                        child:
                            Center(child: FileTypeIcon(item: item, size: 36)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (multiSelecting)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Checkbox(
                          value: selected,
                          onChanged: (_) => onSelect(item),
                        ),
                      ),
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
            onDoubleTap: multiSelecting ? null : () => onOpen(item),
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
                  if (multiSelecting)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Checkbox(
                        value: selected,
                        onChanged: (_) => onSelect(item),
                      ),
                    )
                  else if (item.isDirectory)
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
    final controller = AppScope.of(context);
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
            padding: const EdgeInsets.all(16),
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
                      _kv('路径', controller.displayPath(item!.path)),
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
                      if (canDownload &&
                          onDownload != null &&
                          !item!.isDirectory)
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
                              onPressed: item!.isDirectory
                                  ? onOpen
                                  : (onPreview ?? onOpen),
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
                              backgroundColor: CupertinoDesktopTokens.danger
                                  .withValues(alpha: 0.12),
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
