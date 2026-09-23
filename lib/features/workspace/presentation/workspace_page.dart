import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../../app/router/route_names.dart';
import '../../../app/theme/cupertino_desktop.dart';
import '../../../core/utils/download_directory.dart';
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

/// 打开系统文件选择器并将选中的一个或多个文件上传到当前目录。
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
    final picked = await FilePicker.pickFiles(
      type: fromAlbum ? FileType.image : FileType.any,
    );
    if (picked.isEmpty) return;
    for (final file in picked) {
      final localPath = file.path;
      if (localPath == null || localPath.isEmpty) {
        throw StateError('无法获取所选文件路径');
      }
      await controller.uploadFile(
        fileName: file.name,
        localPath: localPath,
        fileSize: await file.length(),
      );
    }
    if (context.mounted) {
      AppFeedback.showSnack(context, '已创建 ${picked.length} 个文件的上传任务');
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

/// 选择本地文件夹，将其中内容按原有层级上传到当前目录。
Future<void> pickAndUploadDirectory(BuildContext context) async {
  final controller = AppScope.read(context);
  if (!controller.capabilities.upload) {
    AppFeedback.showSnack(context, '当前身份没有上传权限');
    return;
  }

  try {
    final selectedPath = await FilePicker.getDirectoryPath(
      dialogTitle: '选择要上传的文件夹',
    );
    if (selectedPath == null || selectedPath.isEmpty) return;

    final directory = Directory(selectedPath);
    if (!await directory.exists()) {
      throw StateError('所选文件夹不存在或无法访问');
    }
    final rootPath = directory.path.replaceAll('\\', '/').replaceFirst(
          RegExp(r'/+$'),
          '',
        );
    final folderName = rootPath.split('/').last;
    final uploadRoot = controller.currentPath;
    if (folderName.isEmpty) throw StateError('无法获取文件夹名称');

    final entities =
        await directory.list(recursive: true, followLinks: false).toList();
    final folders = <String>[''];
    final files = <File>[];
    for (final entity in entities) {
      final entityPath = entity.path.replaceAll('\\', '/');
      if (!entityPath.startsWith('$rootPath/')) continue;
      final relativePath = entityPath.substring(rootPath.length + 1);
      if (entity is Directory) {
        folders.add(relativePath);
      } else if (entity is File) {
        files.add(entity);
      }
    }

    for (final relativePath in folders) {
      final name =
          relativePath.isEmpty ? folderName : '$folderName/$relativePath';
      await controller.createFolder(name, targetPath: uploadRoot);
    }
    for (final file in files) {
      final relativePath = file.path.replaceAll('\\', '/').substring(
            rootPath.length + 1,
          );
      final segments = relativePath.split('/');
      final fileName = segments.removeLast();
      final parent =
          segments.isEmpty ? folderName : '$folderName/${segments.join('/')}';
      await controller.uploadFile(
        fileName: fileName,
        localPath: file.path,
        fileSize: await file.length(),
        targetPath: '$uploadRoot$parent/',
      );
    }
    if (context.mounted) {
      AppFeedback.showSnack(context, '已创建 ${files.length} 个文件的上传任务');
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
  final FocusNode _itemsFocusNode = FocusNode(
    debugLabel: 'workspace-items',
  );
  String? _boundPath;
  int? _boundTreeRevision;
  String? _renamingPath;

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

  @override
  void dispose() {
    _itemsFocusNode.dispose();
    super.dispose();
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

  Future<void> _setSortOption(FileSortOption option) async {
    final controller = AppScope.of(context);
    await controller.setFileSortOption(option);
    if (mounted) await _reload();
  }

  void _showSortSheet() {
    final current = AppScope.read(context).fileSortOption;
    showModalBottomSheet<FileSortOption>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const ListTile(title: Text('排序方式')),
            for (final option in FileSortOption.values)
              ListTile(
                title: Text(option.label),
                trailing: option == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(sheetContext).pop(option),
              ),
          ],
        ),
      ),
    ).then((option) {
      if (option != null) _setSortOption(option);
    });
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
          return Listener(
            onPointerDown: (_) {
              if (desktop) {
                _itemsFocusNode.requestFocus();
              }
            },
            child: Focus(
              focusNode: _itemsFocusNode,
              onKeyEvent: (_, event) {
                if (desktop && event is KeyDownEvent) {
                  if (HardwareKeyboard.instance.isMetaPressed &&
                      event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    unawaited(_goUp());
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
                      event.logicalKey == LogicalKeyboardKey.arrowDown ||
                      event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                      event.logicalKey == LogicalKeyboardKey.arrowRight) {
                    return KeyEventResult.handled;
                  }
                }
                return KeyEventResult.ignored;
              },
              child: _EmptyState(
                canUpload: canUpload,
                onAction: canUpload
                    ? (desktop
                        ? () => _pickUpload(fromAlbum: false)
                        : _showUploadSheet)
                    : null,
              ),
            ),
          );
        }

        return Listener(
          onPointerDown: (_) {
            if (desktop) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  _itemsFocusNode.requestFocus();
                }
              });
            }
          },
          child: Focus(
            key: const ValueKey<String>('workspace-items-focus'),
            focusNode: _itemsFocusNode,
            descendantsAreFocusable: _renamingPath != null,
            onKeyEvent: (node, event) {
              if (desktop && event is KeyDownEvent) {
                if (event.logicalKey == LogicalKeyboardKey.escape &&
                    controller.isMultiSelectionMode) {
                  controller.clearMultiSelection();
                  return KeyEventResult.handled;
                }
                if (HardwareKeyboard.instance.isMetaPressed &&
                    event.logicalKey == LogicalKeyboardKey.keyA) {
                  controller.selectAllItems(items);
                  return KeyEventResult.handled;
                }
                if (HardwareKeyboard.instance.isMetaPressed) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    unawaited(_goUp());
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    final selected = controller.selectedItem;
                    if (selected != null) {
                      unawaited(_handleOpen(selected));
                    }
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                      event.logicalKey == LogicalKeyboardKey.arrowRight) {
                    return KeyEventResult.handled;
                  }
                }
                if (HardwareKeyboard.instance.isShiftPressed) {
                  return switch (event.logicalKey) {
                    LogicalKeyboardKey.arrowUp ||
                    LogicalKeyboardKey.arrowDown ||
                    LogicalKeyboardKey.arrowLeft ||
                    LogicalKeyboardKey.arrowRight =>
                      KeyEventResult.handled,
                    _ => KeyEventResult.ignored,
                  };
                }
                final isGrid = controller.browseMode == BrowseMode.grid;
                final offset = switch (event.logicalKey) {
                  LogicalKeyboardKey.arrowUp => isGrid
                      ? -_gridColumnCount(
                          node,
                          items.length,
                          controller.thumbnailSize,
                        )
                      : -1,
                  LogicalKeyboardKey.arrowDown => isGrid
                      ? _gridColumnCount(
                          node,
                          items.length,
                          controller.thumbnailSize,
                        )
                      : 1,
                  LogicalKeyboardKey.arrowLeft => isGrid ? -1 : 0,
                  LogicalKeyboardKey.arrowRight => isGrid ? 1 : 0,
                  _ => 0,
                };
                if (offset != 0 &&
                    controller.moveSelection(
                      items,
                      offset: offset,
                    )) {
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                    event.logicalKey == LogicalKeyboardKey.arrowRight) {
                  return KeyEventResult.handled;
                }
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
                      selectedCount: selectedItems.length,
                      allSelected: selectedItems.length == items.length,
                      itemCount: items.length,
                      canDownload: controller.capabilities.download,
                      canDelete: controller.capabilities.delete,
                      onSelectAll: () {
                        if (selectedItems.length == items.length) {
                          controller.clearMultiSelection();
                        } else {
                          controller.selectAllItems(items);
                        }
                      },
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
                          final selecting = controller.isMultiSelectionMode;
                          final isMultiSelectionMode =
                              controller.isMultiSelectionMode;
                          void onSelect(FileItem item) {
                            if (desktop) {
                              _itemsFocusNode.requestFocus();
                            }
                            if (isMultiSelectionMode) {
                              _toggleMultiSelection(item, items);
                            } else {
                              _handleSelect(item);
                            }
                          }

                          if (controller.browseMode == BrowseMode.grid) {
                            return WorkspaceGridView(
                              items: items,
                              selectedPath: selectedPath,
                              selectedPaths: selectedPaths,
                              multiSelecting: selecting,
                              desktop: desktop,
                              thumbnailSize: controller.thumbnailSize,
                              subtitleBuilder: _subtitle,
                              thumbnailLoader: controller.loadThumbnail,
                              thumbnailCacheNamespace:
                                  controller.thumbnailCacheNamespace,
                              onOpen: _handleOpen,
                              onMore: desktop ? (_) {} : _showItemActions,
                              onSelect: onSelect,
                              onToggle: (item) =>
                                  _toggleMultiSelection(item, items),
                              onMarqueeSelectionChanged:
                                  controller.replaceMultiSelection,
                              canUpload: canUpload,
                              canDelete: controller.capabilities.delete,
                              canDownload: controller.capabilities.download,
                              onDownload: _download,
                              onRename: _rename,
                              renamingPath: _renamingPath,
                              onRenameSubmit: _commitRename,
                              onRenameCancel: _cancelRename,
                              onDelete: _delete,
                            );
                          }
                          return WorkspaceListView(
                            items: items,
                            desktop: desktop,
                            selectedPath: selectedPath,
                            selectedPaths: selectedPaths,
                            multiSelecting: selecting,
                            subtitleBuilder: _subtitle,
                            metaTimeBuilder: _metaTime,
                            canUpload: canUpload,
                            canDelete: controller.capabilities.delete,
                            canDownload: controller.capabilities.download,
                            onOpen: _handleOpen,
                            onMore: desktop ? (_) {} : _showItemActions,
                            onSelect: onSelect,
                            onToggle: (item) =>
                                _toggleMultiSelection(item, items),
                            onMarqueeSelectionChanged:
                                controller.replaceMultiSelection,
                            onPreview: _openPreview,
                            onDownload: _download,
                            onRename: _rename,
                            renamingPath: _renamingPath,
                            onRenameSubmit: _commitRename,
                            onRenameCancel: _cancelRename,
                            onDelete: _delete,
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  int _gridColumnCount(
    FocusNode node,
    int itemCount,
    ThumbnailSize thumbnailSize,
  ) {
    final box = node.context?.findRenderObject() as RenderBox?;
    final width = box?.size.width;
    if (width == null || width <= 0) {
      return 1;
    }
    final maxCrossAxisExtent = thumbnailSize.maxCrossAxisExtent(desktop: true);
    const crossAxisSpacing = 12.0;
    final count =
        ((width + crossAxisSpacing) / (maxCrossAxisExtent + crossAxisSpacing))
            .ceil();
    return count.clamp(1, itemCount);
  }

  Future<void> _openDirectory(String path) async {
    final controller = AppScope.of(context);
    controller.setCurrentPath(path);
    await _reload();
    if (mounted && _desktop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _itemsFocusNode.requestFocus();
        }
      });
    }
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

  void _rename(FileItem item) {
    final controller = AppScope.of(context);
    if (!controller.capabilities.upload && !controller.capabilities.delete) {
      AppFeedback.showSnack(context, '当前身份没有重命名权限');
      return;
    }
    setState(() => _renamingPath = item.path);
  }

  void _cancelRename() {
    if (_renamingPath != null) {
      setState(() => _renamingPath = null);
    }
  }

  Future<bool> _commitRename(FileItem item, String name) async {
    final trimmedName = name.trim();
    if (trimmedName == item.name) {
      _cancelRename();
      return true;
    }
    if (trimmedName.isEmpty) {
      AppFeedback.showSnack(context, '名称不能为空');
      return false;
    }
    final controller = AppScope.of(context);
    try {
      await controller.renameItem(item, trimmedName);
      _cancelRename();
      await _reload();
      if (mounted) {
        AppFeedback.showSnack(context, '已重命名为 $trimmedName');
      }
      return true;
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
      return false;
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
      message: '将“${item.name}”移入回收站，30 天内可恢复。',
      confirmLabel: '移入回收站',
      destructive: true,
    );
    if (!confirmed) {
      return;
    }
    try {
      await controller.deleteItem(item);
      await _reload();
      if (mounted) {
        AppFeedback.showSnack(context, '已移入回收站：${item.name}');
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
    if (item.isDirectory) {
      await _downloadSelected(<FileItem>[item]);
      return;
    }
    final controller = AppScope.of(context);
    try {
      final mediaFile = _isAndroidMediaFile(item.name);
      final directory = mediaFile ? '系统相册' : await selectDownloadDirectory();
      if (directory == null) {
        return;
      }
      controller.enqueueDownload(item, targetDirectory: directory);
      if (mounted) {
        AppFeedback.showSnack(
          context,
          mediaFile ? '已加入相册下载队列：${item.name}' : '已加入下载队列：${item.name}',
        );
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

  bool _isAndroidMediaFile(String name) {
    if (!Platform.isAndroid) return false;
    final extension = name.split('.').last.toLowerCase();
    return const <String>{
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'heic',
      'mp4',
      'mov',
      'mkv',
      'avi',
      'webm',
      '3gp',
    }.contains(extension);
  }

  Future<void> _downloadSelected(List<FileItem> items) async {
    final controller = AppScope.of(context);
    final directory = await selectDownloadDirectory();
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
        message:
            '其中包含 ${preview.directoryCount} 个文件夹，共影响 ${preview.objectCount} 个对象。'
            '将移入回收站，30 天内可恢复。',
        confirmLabel: '移入回收站',
        destructive: true,
      );
      if (!confirmed) return;
      var result = await controller.deleteBatch(preview);
      if (result.failedPaths.isNotEmpty && mounted) {
        final retry = await AppFeedback.confirm(
          context,
          title: '部分删除失败',
          message:
              '已删除 ${result.deletedPaths.length} 项，${result.failedPaths.length} 项失败。是否重试失败项？',
          confirmLabel: '重试失败项',
        );
        if (retry) {
          final retried = await controller.retryBatchDelete(result.failedPaths);
          result = BatchDeleteSummary(
            deletedPaths: <String>[
              ...result.deletedPaths,
              ...retried.deletedPaths
            ],
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
              ? '已移入回收站 ${result.deletedPaths.length} 项'
              : '已移入回收站 ${result.deletedPaths.length} 项，${result.failedPaths.length} 项失败',
        );
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
            context, error.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  Future<void> _pickUpload({required bool fromAlbum}) async {
    await pickAndUploadFile(context, fromAlbum: fromAlbum);
    if (mounted) await _reload();
  }

  Future<void> _pickUploadDirectory() async {
    await pickAndUploadDirectory(context);
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
                leading: const Icon(Icons.drive_folder_upload_outlined),
                title: const Text('上传文件夹'),
                onTap: () {
                  Navigator.pop(context);
                  _pickUploadDirectory();
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
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.82,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ListTile(
                    title: Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    subtitle: Text(
                      controller.displayPath(item.path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ListTile(
                    leading: Icon(item.isDirectory
                        ? Icons.open_in_new
                        : Icons.visibility_outlined),
                    title: Text(item.isDirectory ? '打开' : '预览'),
                    onTap: () {
                      Navigator.pop(context);
                      _handleOpen(item);
                    },
                  ),
                  if (controller.capabilities.download)
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
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        _delete(item);
                      },
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _subtitle(FileItem item) {
    final parts = <String>[
      item.isDirectory && item.itemCount != null
          ? '${item.itemCount} 项'
          : item.typeLabel,
    ];
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
      backgroundColor: desktop ? scheme.surface : theme.scaffoldBackgroundColor,
      floatingActionButton: desktop || !canUpload
          ? null
          : FloatingActionButton(
              onPressed: _showUploadSheet,
              child: const Icon(Icons.add),
            ),
      body: SafeArea(
        top: !desktop,
        child: desktop
            ? WorkspaceDesktopBody(
                path: controller.displayPath(controller.currentPath),
                canGoUp: controller.currentPath != AppController.rootPrefix,
                canUpload: canUpload,
                canDelete: canDelete,
                canDownload: canDownload,
                browseMode: controller.browseMode,
                thumbnailSize: controller.thumbnailSize,
                sortOption: controller.fileSortOption,
                selectedListenable: controller.selectedItemListenable,
                directorySizeStatesListenable:
                    controller.directorySizeStatesListenable,
                listArea: _buildItemsArea(
                  controller: controller,
                  desktop: true,
                  canUpload: canUpload,
                ),
                onGoUp: _goUp,
                onRefresh: _reload,
                onCreateFolder: _createFolder,
                onUpload: () => _pickUpload(fromAlbum: false),
                onUploadDirectory: _pickUploadDirectory,
                onBrowseModeChanged: controller.setBrowseMode,
                onThumbnailSizeChanged: controller.setThumbnailSize,
                onSortChanged: _setSortOption,
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
                    WorkspaceMobileHeader(
                      path: controller.displayPath(controller.currentPath),
                      roleLabel: controller.session?.displayName ?? '成员',
                      canGoUp:
                          controller.currentPath != AppController.rootPrefix,
                      browseMode: controller.browseMode,
                      thumbnailSize: controller.thumbnailSize,
                      sortOption: controller.fileSortOption,
                      onGoUp: _goUp,
                      onRefresh: _reload,
                      onBrowseModeChanged: controller.setBrowseMode,
                      onThumbnailSizeChanged: controller.setThumbnailSize,
                      onChooseSort: _showSortSheet,
                    ),
                    const SizedBox(height: 12),
                    if (!canUpload || !canDelete)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '当前用户缺少部分文件操作权限。',
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
    required this.selectedCount,
    required this.allSelected,
    required this.itemCount,
    required this.canDownload,
    required this.canDelete,
    required this.onSelectAll,
    this.onDownload,
    this.onDelete,
  });

  final int selectedCount;
  final bool allSelected;
  final int itemCount;
  final bool canDownload;
  final bool canDelete;
  final VoidCallback onSelectAll;
  final VoidCallback? onDownload;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
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
          Checkbox(
            value: allSelected && itemCount > 0
                ? true
                : selectedCount > 0
                    ? null
                    : false,
            tristate: true,
            onChanged: itemCount == 0 ? null : (_) => onSelectAll(),
          ),
          Text(
            selectedCount > 0 ? '已选 $selectedCount 项' : '已全部加载，共 $itemCount 项',
            style:
                TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurface),
          ),
          if (selectedCount > 0 && canDownload)
            FilledButton.icon(
              onPressed: onDownload,
              style: compactButtonStyle,
              icon: const Icon(Icons.download_outlined),
              label: const Text('下载'),
            ),
          if (selectedCount > 0 && canDelete)
            TextButton.icon(
              onPressed: onDelete,
              style: compactButtonStyle.copyWith(
                foregroundColor: WidgetStatePropertyAll<Color>(scheme.error),
              ),
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除'),
            ),
        ],
      ),
    );
  }
}

class WorkspaceDesktopBody extends StatelessWidget {
  const WorkspaceDesktopBody({
    required this.path,
    required this.canGoUp,
    required this.canUpload,
    required this.canDelete,
    required this.canDownload,
    required this.browseMode,
    required this.thumbnailSize,
    required this.sortOption,
    required this.selectedListenable,
    required this.directorySizeStatesListenable,
    required this.listArea,
    required this.onGoUp,
    required this.onRefresh,
    required this.onCreateFolder,
    required this.onUpload,
    required this.onUploadDirectory,
    required this.onBrowseModeChanged,
    required this.onThumbnailSizeChanged,
    required this.onSortChanged,
    required this.onOpen,
    required this.onPreview,
    required this.onDownload,
    required this.onDelete,
    this.detailBuilder,
    this.showPermissionNotice = true,
  });

  final String path;
  final bool canGoUp;
  final bool canUpload;
  final bool canDelete;
  final bool canDownload;
  final BrowseMode browseMode;
  final ThumbnailSize thumbnailSize;
  final FileSortOption sortOption;
  final ValueNotifier<FileItem?> selectedListenable;
  final ValueNotifier<Map<String, DirectorySizeState>>
      directorySizeStatesListenable;
  final Widget listArea;
  final VoidCallback onGoUp;
  final VoidCallback onRefresh;
  final VoidCallback onCreateFolder;
  final VoidCallback onUpload;
  final VoidCallback onUploadDirectory;
  final ValueChanged<BrowseMode> onBrowseModeChanged;
  final ValueChanged<ThumbnailSize> onThumbnailSizeChanged;
  final ValueChanged<FileSortOption> onSortChanged;
  final ValueChanged<FileItem> onOpen;
  final ValueChanged<FileItem> onPreview;
  final ValueChanged<FileItem> onDownload;
  final ValueChanged<FileItem> onDelete;
  final Widget Function(FileItem?)? detailBuilder;
  final bool showPermissionNotice;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
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
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: Theme.of(context).colorScheme.onSurface,
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
                  if (browseMode == BrowseMode.grid)
                    _ThumbnailSizeSegmented(
                      thumbnailSize: thumbnailSize,
                      onChanged: onThumbnailSizeChanged,
                    ),
                  PopupMenuButton<FileSortOption>(
                    tooltip: '排序',
                    onSelected: onSortChanged,
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    elevation: 10,
                    shadowColor: Colors.black26,
                    offset: const Offset(0, 42),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    itemBuilder: (context) => FileSortOption.values
                        .map(
                          (option) => CheckedPopupMenuItem<FileSortOption>(
                            value: option,
                            checked: option == sortOption,
                            child: Text(option.label),
                          ),
                        )
                        .toList(growable: false),
                    // 保持与“刷新”等工具栏按钮同一视觉语言；点击由外层菜单处理。
                    child: IgnorePointer(
                      child: OutlinedButton.icon(
                        onPressed: () {},
                        icon: const Icon(Icons.sort, size: 18),
                        label: Text('排序：${sortOption.shortLabel}'),
                      ),
                    ),
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
                    FilledButton(
                      onPressed: onUploadDirectory,
                      child: const Text('上传文件夹'),
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
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (showPermissionNotice && (!canUpload || !canDelete)) ...<Widget>[
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
                            '当前用户缺少上传或删除权限。',
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
                    return ValueListenableBuilder<
                        Map<String, DirectorySizeState>>(
                      valueListenable: directorySizeStatesListenable,
                      builder: (context, directorySizes, _) => detailBuilder
                          ?.call(current) ??
                          _DetailPanel(
                            item: current,
                            directorySize: current == null || !current.isDirectory
                                ? null
                                : directorySizes[current.path],
                          ),
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
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
      color:
          selected ? Theme.of(context).colorScheme.surface : Colors.transparent,
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
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _ThumbnailSizeSegmented extends StatelessWidget {
  const _ThumbnailSizeSegmented({
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
              (size) => _SegButton(
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

class _MobileThumbnailSizeMenu extends StatelessWidget {
  const _MobileThumbnailSizeMenu({
    required this.thumbnailSize,
    required this.onChanged,
  });

  final ThumbnailSize thumbnailSize;
  final ValueChanged<ThumbnailSize> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<ThumbnailSize>(
      tooltip: '缩略图大小：${thumbnailSize.label}',
      initialValue: thumbnailSize,
      onSelected: onChanged,
      itemBuilder: (context) => ThumbnailSize.values
          .map(
            (size) => CheckedPopupMenuItem<ThumbnailSize>(
              value: size,
              checked: size == thumbnailSize,
              child: Text('${size.label}图'),
            ),
          )
          .toList(growable: false),
      child: const Padding(
        padding: EdgeInsets.all(8),
        child: Icon(Icons.photo_size_select_large_outlined),
      ),
    );
  }
}

class WorkspaceMobileHeader extends StatelessWidget {
  const WorkspaceMobileHeader({
    required this.path,
    required this.roleLabel,
    required this.canGoUp,
    required this.browseMode,
    required this.thumbnailSize,
    required this.sortOption,
    required this.onGoUp,
    required this.onRefresh,
    required this.onBrowseModeChanged,
    required this.onThumbnailSizeChanged,
    required this.onChooseSort,
    this.title = '共享空间',
  });

  final String path;
  final String roleLabel;
  final bool canGoUp;
  final BrowseMode browseMode;
  final ThumbnailSize thumbnailSize;
  final FileSortOption sortOption;
  final VoidCallback onGoUp;
  final VoidCallback onRefresh;
  final ValueChanged<BrowseMode> onBrowseModeChanged;
  final ValueChanged<ThumbnailSize> onThumbnailSizeChanged;
  final VoidCallback onChooseSort;
  final String title;

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
                  Text(title, style: theme.textTheme.headlineSmall),
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
              onPressed: onChooseSort,
              icon: const Icon(Icons.sort),
              tooltip: '排序：${sortOption.label}',
            ),
            IconButton(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: SegmentedButton<BrowseMode>(
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
                onSelectionChanged: (values) =>
                    onBrowseModeChanged(values.first),
              ),
            ),
            if (browseMode == BrowseMode.grid) ...<Widget>[
              const SizedBox(width: 8),
              _MobileThumbnailSizeMenu(
                thumbnailSize: thumbnailSize,
                onChanged: onThumbnailSizeChanged,
              ),
            ],
          ],
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant,
          style: BorderStyle.solid,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '当前目录为空',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            canUpload ? '可以新建文件夹或上传文件。' : '当前目录暂无内容。',
            style: TextStyle(
              fontSize: 13,
              height: 1.55,
              color: scheme.onSurfaceVariant,
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

class WorkspaceListView extends StatelessWidget {
  const WorkspaceListView({
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
    required this.onToggle,
    required this.onMarqueeSelectionChanged,
    required this.onPreview,
    required this.onDownload,
    required this.onRename,
    required this.renamingPath,
    required this.onRenameSubmit,
    required this.onRenameCancel,
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
  final ValueChanged<FileItem> onToggle;
  final ValueChanged<Set<String>> onMarqueeSelectionChanged;
  final ValueChanged<FileItem> onPreview;
  final ValueChanged<FileItem> onDownload;
  final ValueChanged<FileItem> onRename;
  final String? renamingPath;
  final Future<bool> Function(FileItem item, String name) onRenameSubmit;
  final VoidCallback onRenameCancel;
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
              dense: true,
              visualDensity: const VisualDensity(vertical: -2),
              contentPadding: const EdgeInsets.only(left: 12, right: 4),
              horizontalTitleGap: 10,
              minLeadingWidth: 28,
              minVerticalPadding: 5,
              leading: multiSelecting
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
              title: renamingPath == item.path
                  ? _InlineRenameField(
                      item: item,
                      onSubmit: onRenameSubmit,
                      onCancel: onRenameCancel,
                    )
                  : Text(
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
                style: Theme.of(context).textTheme.bodySmall,
              ),
              onTap: () {
                onSelect(item);
                if (!multiSelecting) onOpen(item);
              },
              onLongPress: () => onToggle(item),
              trailing: IconButton(
                tooltip: '更多',
                visualDensity: VisualDensity.compact,
                constraints:
                    const BoxConstraints.tightFor(width: 40, height: 40),
                onPressed: () => onMore(item),
                icon: const Icon(Icons.more_vert, size: 20),
              ),
            );
          },
        ),
      );
    }

    return _DesktopMarqueeSelection(
      enabled: desktop && defaultTargetPlatform == TargetPlatform.macOS,
      items: items,
      selectedPaths: selectedPaths,
      onSelectionChanged: onMarqueeSelectionChanged,
      childBuilder: (context, itemKeys, marqueeSelecting, onItemPointerDown) =>
          Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
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
            final selected = selectedPaths.isNotEmpty
                ? selectedPaths.contains(item.path)
                : item.path == selectedPath;
            return Listener(
              onPointerDown: (event) => onItemPointerDown(event.pointer),
              child: Material(
                key: itemKeys[index],
                color: selected
                    ? CupertinoDesktopTokens.blue.withValues(alpha: 0.12)
                    : Colors.transparent,
                child: GestureDetector(
                  onSecondaryTapDown: (details) => _showDesktopItemMenu(
                    context: context,
                    position: details.globalPosition,
                    item: item,
                    canDownload: canDownload,
                    canRename: canUpload || canDelete,
                    canDelete: canDelete,
                    onOpen: () => onOpen(item),
                    onPreview: () => onPreview(item),
                    onDownload: () => onDownload(item),
                    onRename: () => onRename(item),
                    onDelete: () => onDelete(item),
                  ),
                  child: InkWell(
                    onTap: () => onSelect(item),
                    onDoubleTap:
                        selectedPaths.isNotEmpty ? null : () => onOpen(item),
                    hoverColor:
                        CupertinoDesktopTokens.blue.withValues(alpha: 0.04),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 11),
                      child: Row(
                        children: <Widget>[
                          if (multiSelecting) ...<Widget>[
                            _HoverCheckbox(
                              value: selected,
                              onChanged: () => onToggle(item),
                            ),
                            const SizedBox(width: 6),
                          ],
                          FileTypeBadge(item: item),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                if (renamingPath == item.path)
                                  _InlineRenameField(
                                    item: item,
                                    onSubmit: onRenameSubmit,
                                    onCancel: onRenameCancel,
                                  )
                                else
                                  Text(
                                    item.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface,
                                    ),
                                  ),
                                const SizedBox(height: 2),
                                Text(
                                  item.isDirectory
                                      ? item.itemCount == null
                                          ? item.typeLabel
                                          : '${item.itemCount} 项'
                                      : '${item.typeLabel} · ${FileSizeFormatter.format(item.size ?? 0)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            metaTimeBuilder(item),
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class WorkspaceGridView extends StatelessWidget {
  const WorkspaceGridView({
    required this.items,
    required this.selectedPath,
    required this.selectedPaths,
    required this.multiSelecting,
    required this.desktop,
    required this.thumbnailSize,
    required this.subtitleBuilder,
    required this.thumbnailLoader,
    required this.thumbnailCacheNamespace,
    required this.onOpen,
    required this.onMore,
    required this.onSelect,
    required this.onToggle,
    required this.onMarqueeSelectionChanged,
    required this.canUpload,
    required this.canDelete,
    required this.canDownload,
    required this.onDownload,
    required this.onRename,
    required this.renamingPath,
    required this.onRenameSubmit,
    required this.onRenameCancel,
    required this.onDelete,
  });

  final List<FileItem> items;
  final String? selectedPath;
  final Set<String> selectedPaths;
  final bool multiSelecting;
  final bool desktop;
  final ThumbnailSize thumbnailSize;
  final String Function(FileItem) subtitleBuilder;
  final Future<List<int>> Function(FileItem item) thumbnailLoader;
  final String thumbnailCacheNamespace;
  final ValueChanged<FileItem> onOpen;
  final ValueChanged<FileItem> onMore;
  final ValueChanged<FileItem> onSelect;
  final ValueChanged<FileItem> onToggle;
  final ValueChanged<Set<String>> onMarqueeSelectionChanged;
  final bool canUpload;
  final bool canDelete;
  final bool canDownload;
  final ValueChanged<FileItem> onDownload;
  final ValueChanged<FileItem> onRename;
  final String? renamingPath;
  final Future<bool> Function(FileItem item, String name) onRenameSubmit;
  final VoidCallback onRenameCancel;
  final ValueChanged<FileItem> onDelete;

  @override
  Widget build(BuildContext context) {
    final gridDelegate = desktop
        ? SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: thumbnailSize.maxCrossAxisExtent(desktop: true),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: thumbnailSize.childAspectRatio(desktop: true),
          )
        : SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: thumbnailSize.mobileCrossAxisCount,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            // 移动端多选会额外显示复选框；预留纵向空间，避免真机字体
            // 或系统缩放下缩略图卡片底部溢出。
            childAspectRatio: thumbnailSize.childAspectRatio(desktop: false),
          );
    return _DesktopMarqueeSelection(
      enabled: desktop && defaultTargetPlatform == TargetPlatform.macOS,
      items: items,
      selectedPaths: selectedPaths,
      onSelectionChanged: onMarqueeSelectionChanged,
      childBuilder: (context, itemKeys, marqueeSelecting, onItemPointerDown) =>
          GridView.builder(
        gridDelegate: gridDelegate,
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          final selected = selectedPaths.isNotEmpty
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
                onLongPress: () => onToggle(item),
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
                          child: FileTypeThumbnail(
                            item: item,
                            height: double.infinity,
                            loader: thumbnailLoader,
                            cacheNamespace: thumbnailCacheNamespace,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (multiSelecting)
                        Align(
                          alignment: Alignment.centerRight,
                          child: Checkbox(
                            value: selected,
                            onChanged: (_) => onToggle(item),
                          ),
                        ),
                      if (renamingPath == item.path)
                        _InlineRenameField(
                          item: item,
                          onSubmit: onRenameSubmit,
                          onCancel: onRenameCancel,
                        )
                      else
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

          return Listener(
            onPointerDown: (event) => onItemPointerDown(event.pointer),
            child: Material(
              key: itemKeys[index],
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              child: GestureDetector(
                onSecondaryTapDown: (details) => _showDesktopItemMenu(
                  context: context,
                  position: details.globalPosition,
                  item: item,
                  canDownload: canDownload,
                  canRename: canUpload || canDelete,
                  canDelete: canDelete,
                  onOpen: () => onOpen(item),
                  onPreview: () => onOpen(item),
                  onDownload: () => onDownload(item),
                  onRename: () => onRename(item),
                  onDelete: () => onDelete(item),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => onSelect(item),
                  onDoubleTap: () => onOpen(item),
                  child: Stack(
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: selected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .outlineVariant),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Expanded(
                                child: FileTypeThumbnail(
                                    item: item,
                                    height: double.infinity,
                                    loader: thumbnailLoader,
                                    cacheNamespace: thumbnailCacheNamespace)),
                            const SizedBox(height: 8),
                            if (renamingPath == item.path)
                              _InlineRenameField(
                                item: item,
                                onSubmit: onRenameSubmit,
                                onCancel: onRenameCancel,
                              )
                            else
                              Text(item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface)),
                          ],
                        ),
                      ),
                      if (multiSelecting)
                        Positioned(
                          top: 4,
                          left: 4,
                          child: _HoverCheckbox(
                            value: selected,
                            onChanged: () => onToggle(item),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 桌面端在文件区域拖拽时绘制选框，并将与选框相交的可见条目交给
/// 既有的多选状态管理。普通点击不会越过拖拽阈值，因此不影响单击、双击。
class _DesktopMarqueeSelection extends StatefulWidget {
  const _DesktopMarqueeSelection({
    required this.enabled,
    required this.items,
    required this.selectedPaths,
    required this.onSelectionChanged,
    required this.childBuilder,
  });

  final bool enabled;
  final List<FileItem> items;
  final Set<String> selectedPaths;
  final ValueChanged<Set<String>> onSelectionChanged;
  final Widget Function(
    BuildContext context,
    List<GlobalKey> itemKeys,
    bool marqueeSelecting,
    ValueChanged<int> onItemPointerDown,
  ) childBuilder;

  @override
  State<_DesktopMarqueeSelection> createState() =>
      _DesktopMarqueeSelectionState();
}

class _DesktopMarqueeSelectionState extends State<_DesktopMarqueeSelection> {
  final GlobalKey _selectionAreaKey = GlobalKey();
  List<GlobalKey> _itemKeys = <GlobalKey>[];
  List<String> _itemKeyPaths = <String>[];
  Offset? _startPosition;
  Offset? _currentPosition;
  int? _activePointer;
  Offset? _pendingStartPosition;
  final Set<int> _itemPointers = <int>{};
  Set<String> _initialPaths = <String>{};

  void _syncItemKeys() {
    final paths = widget.items.map((item) => item.path).toList(growable: false);
    if (_itemKeyPaths.length == paths.length &&
        _itemKeyPaths.indexed.every((entry) => entry.$2 == paths[entry.$1])) {
      return;
    }
    _itemKeyPaths = paths;
    // 同一路径的异常重复条目也必须拥有各自独立的 GlobalKey。
    _itemKeys = List<GlobalKey>.generate(paths.length, (_) => GlobalKey());
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled ||
        event.kind != PointerDeviceKind.mouse ||
        event.buttons & kPrimaryButton == 0) {
      return;
    }
    _activePointer = event.pointer;
    _pendingStartPosition = event.localPosition;
  }

  void _recordItemPointerDown(int pointer) {
    _itemPointers.add(pointer);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_activePointer != event.pointer) return;
    final pendingStart = _pendingStartPosition;
    if (_startPosition == null && pendingStart != null) {
      if ((event.localPosition - pendingStart).distance < kTouchSlop) return;
      _startSelection(pendingStart);
    }
    _updateSelection(event.localPosition);
  }

  void _startSelection(Offset position) {
    if (!widget.enabled) return;
    final preserveSelection = HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    setState(() {
      _startPosition = position;
      _currentPosition = position;
      _initialPaths = preserveSelection
          ? Set<String>.from(widget.selectedPaths)
          : <String>{};
    });
    _updateSelection(position);
  }

  void _updateSelection(Offset position) {
    setState(() => _currentPosition = position);
    final start = _startPosition;
    final current = _currentPosition;
    final selectionArea =
        _selectionAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (start == null || current == null || selectionArea == null) return;

    final globalOrigin = selectionArea.localToGlobal(Offset.zero);
    final selection = Rect.fromPoints(
      globalOrigin + start,
      globalOrigin + current,
    );
    final paths = <String>{..._initialPaths};
    for (var index = 0; index < widget.items.length; index++) {
      final item = widget.items[index];
      final itemBox =
          _itemKeys[index].currentContext?.findRenderObject() as RenderBox?;
      if (itemBox == null || !itemBox.attached) continue;
      final itemOrigin = itemBox.localToGlobal(Offset.zero);
      if (selection.overlaps(itemOrigin & itemBox.size)) {
        paths.add(item.path);
      }
    }
    if (!_samePaths(paths, widget.selectedPaths)) {
      widget.onSelectionChanged(paths);
    }
  }

  void _finishSelection([PointerEvent? event]) {
    if (event != null && _activePointer != event.pointer) return;
    final startedOnItem = event != null && _itemPointers.remove(event.pointer);
    if (event != null && _startPosition == null && !startedOnItem) {
      widget.onSelectionChanged(<String>{});
    }
    _activePointer = null;
    _pendingStartPosition = null;
    if (_startPosition == null) return;
    setState(() {
      _startPosition = null;
      _currentPosition = null;
    });
  }

  bool _samePaths(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);

  @override
  Widget build(BuildContext context) {
    _syncItemKeys();
    final start = _startPosition;
    final current = _currentPosition;
    if (!widget.enabled) {
      return widget.childBuilder(
        context,
        _itemKeys,
        false,
        _recordItemPointerDown,
      );
    }
    final child = widget.childBuilder(
      context,
      _itemKeys,
      start != null,
      _recordItemPointerDown,
    );
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: widget.enabled ? _onPointerDown : null,
      onPointerMove: widget.enabled ? _onPointerMove : null,
      onPointerUp: widget.enabled ? _finishSelection : null,
      onPointerCancel: widget.enabled ? _finishSelection : null,
      child: Stack(
        key: _selectionAreaKey,
        fit: StackFit.expand,
        children: <Widget>[
          child,
          if (start != null && current != null)
            IgnorePointer(
              child: CustomPaint(
                painter: _SelectionRectanglePainter(
                  Rect.fromPoints(start, current),
                  Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SelectionRectanglePainter extends CustomPainter {
  const _SelectionRectanglePainter(this.rect, this.color);

  final Rect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      rect,
      Paint()..color = color.withValues(alpha: 0.14),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _SelectionRectanglePainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.color != color;
}

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({required this.item, this.directorySize});

  final FileItem? item;
  final DirectorySizeState? directorySize;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(
          left: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: scheme.outlineVariant),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '详情预览',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: item == null
                ? Center(
                    child: Text(
                      '选中文件后展示详情',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
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
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _kv(context, '类型', item!.typeLabel),
                      _kv(
                        context,
                        '大小',
                        item!.isDirectory
                            ? _directorySizeLabel(directorySize)
                            : FileSizeFormatter.format(item!.size ?? 0),
                      ),
                      _kv(context, '路径', controller.displayPath(item!.path)),
                      _kv(
                        context,
                        '更新',
                        item!.updatedAt == null
                            ? '—'
                            : _formatTime(item!.updatedAt!),
                      ),
                      if (item!.kind == FileKind.image)
                        _kv(
                          context,
                          '拍摄',
                          item!.takenAt == null
                              ? ''
                              : _formatTime(item!.takenAt!),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _directorySizeLabel(DirectorySizeState? state) {
    if (state == null || state.isLoading) return '正在计算…';
    if (state.size == null) return '暂无法获取';
    return FileSizeFormatter.format(state.size!);
  }

  String _formatTime(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd $hh:$mi';
  }
}

class _HoverCheckbox extends StatefulWidget {
  const _HoverCheckbox({required this.value, required this.onChanged});

  final bool value;
  final VoidCallback onChanged;

  @override
  State<_HoverCheckbox> createState() => _HoverCheckboxState();
}

class _HoverCheckboxState extends State<_HoverCheckbox> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final visible = _hovered || widget.value;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 100),
        child: Checkbox(
          value: widget.value,
          onChanged: (_) => widget.onChanged(),
        ),
      ),
    );
  }
}

class _InlineRenameField extends StatefulWidget {
  const _InlineRenameField({
    required this.item,
    required this.onSubmit,
    required this.onCancel,
  });

  final FileItem item;
  final Future<bool> Function(FileItem item, String name) onSubmit;
  final VoidCallback onCancel;

  @override
  State<_InlineRenameField> createState() => _InlineRenameFieldState();
}

class _InlineRenameFieldState extends State<_InlineRenameField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.item.name);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    _submitting = true;
    final succeeded = await widget.onSubmit(widget.item, _controller.text);
    if (!mounted || succeeded) return;
    setState(() => _submitting = false);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onCancel();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        enabled: !_submitting,
        maxLines: 1,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        onTapOutside: (_) => _submit(),
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: CupertinoDesktopTokens.blue),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: CupertinoDesktopTokens.blue),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(
              color: CupertinoDesktopTokens.blue,
              width: 1.5,
            ),
          ),
        ),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

enum _DesktopItemAction { openOrPreview, download, rename, delete }

Future<void> _showDesktopItemMenu({
  required BuildContext context,
  required Offset position,
  required FileItem item,
  required bool canDownload,
  required bool canRename,
  required bool canDelete,
  required VoidCallback onOpen,
  required VoidCallback onPreview,
  required VoidCallback onDownload,
  required VoidCallback onRename,
  required VoidCallback onDelete,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final action = await showMenu<_DesktopItemAction>(
    context: context,
    color: Theme.of(context).colorScheme.surface,
    surfaceTintColor: Colors.transparent,
    elevation: 10,
    shadowColor: Theme.of(context).colorScheme.shadow,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    position: RelativeRect.fromRect(
      Rect.fromPoints(position, position),
      Offset.zero & overlay.size,
    ),
    items: <PopupMenuEntry<_DesktopItemAction>>[
      _desktopContextMenuItem(
        context: context,
        value: _DesktopItemAction.openOrPreview,
        icon: item.isDirectory ? Icons.folder_open_outlined : Icons.open_in_new,
        label: item.isDirectory ? '打开' : '预览 / 打开',
      ),
      if (canDownload)
        _desktopContextMenuItem(
          context: context,
          value: _DesktopItemAction.download,
          icon: Icons.download_outlined,
          label: '下载',
        ),
      if (canRename)
        _desktopContextMenuItem(
          context: context,
          value: _DesktopItemAction.rename,
          icon: Icons.drive_file_rename_outline,
          label: '重命名',
        ),
      if (canDelete)
        _desktopContextMenuItem(
          context: context,
          value: _DesktopItemAction.delete,
          icon: Icons.delete_outline,
          label: '删除',
          isDestructive: true,
        ),
    ],
  );
  switch (action) {
    case _DesktopItemAction.openOrPreview:
      item.isDirectory ? onOpen() : onPreview();
      break;
    case _DesktopItemAction.download:
      onDownload();
      break;
    case _DesktopItemAction.rename:
      onRename();
      break;
    case _DesktopItemAction.delete:
      onDelete();
      break;
    case null:
      break;
  }
}

PopupMenuItem<_DesktopItemAction> _desktopContextMenuItem({
  required BuildContext context,
  required _DesktopItemAction value,
  required IconData icon,
  required String label,
  bool isDestructive = false,
}) {
  final scheme = Theme.of(context).colorScheme;
  final color = isDestructive ? scheme.error : scheme.onSurface;
  return PopupMenuItem<_DesktopItemAction>(
    value: value,
    height: 40,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: <Widget>[
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w500, color: color),
        ),
      ],
    ),
  );
}
