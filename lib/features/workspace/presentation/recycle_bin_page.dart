import 'package:flutter/material.dart';

import '../../../app/router/route_names.dart';
import '../../../shared/state/app_controller.dart';
import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/file_icon.dart';
import '../../../shared/widgets/file_sort_sheet.dart';
import '../../preview/domain/preview_type.dart';
import '../../preview/presentation/preview_page.dart';
import '../domain/file_item.dart';
import '../domain/recycle_bin_entry.dart';
import 'workspace_page.dart';

/// 复用共享空间浏览器外壳；根层平铺展示每个删除条目，
/// 目录条目可进入查看删除前的内部结构。
class RecycleBinPage extends StatefulWidget {
  const RecycleBinPage({super.key, this.embedded = false, this.visitToken = 0});
  final bool embedded;
  final int? visitToken;
  @override
  State<RecycleBinPage> createState() => _RecycleBinPageState();
}

class _RecycleBinPageState extends State<RecycleBinPage> {
  late Future<List<RecycleBinEntry>> _entriesFuture;
  final ValueNotifier<FileItem?> _selected = ValueNotifier<FileItem?>(null);
  final ValueNotifier<Map<String, DirectorySizeState>> _directorySizes =
      ValueNotifier<Map<String, DirectorySizeState>>(const {});
  bool _initialized = false;
  Map<String, RecycleBinEntry> _itemEntries = <String, RecycleBinEntry>{};
  List<FileItem> _visibleItems = const <FileItem>[];

  bool get _desktop => MediaQuery.sizeOf(context).width >= 960;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _entriesFuture = _load();
  }

  @override
  void didUpdateWidget(covariant RecycleBinPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.visitToken ?? 0) != (oldWidget.visitToken ?? 0)) _reload();
  }

  @override
  void dispose() {
    _selected.dispose();
    _directorySizes.dispose();
    super.dispose();
  }

  Future<List<RecycleBinEntry>> _load() async {
    final entries = await AppScope.of(context).listRecycleBin();
    if (mounted) setState(() {});
    return entries;
  }

  Future<void> _reload() async {
    final future = _load();
    setState(() {
      _entriesFuture = future;
    });
    await future;
  }

  String _folder(String path) => path.endsWith('/') ? path : '$path/';

  static final String _rootDir = _staticFolder(AppController.rootPrefix);
  static final String _trashPrefix =
      _staticFolder('${AppController.rootPrefix}.trash');

  static String _staticFolder(String path) =>
      path.endsWith('/') ? path : '$path/';

  /// 条目内对象共同的原路径前缀（含末段目录名，以 / 结尾），作为条目
  /// 虚拟树与真实源路径之间的映射基准；兼容旧批次与单文件条目。
  String _entryBase(RecycleBinEntry entry) {
    final sources = entry.objects.keys.toList(growable: false);
    if (sources.isEmpty) {
      final original = entry.originalPath.endsWith('/')
          ? entry.originalPath.substring(0, entry.originalPath.length - 1)
          : entry.originalPath;
      final slash = original.lastIndexOf('/');
      return _staticFolder(slash < 0 ? '' : original.substring(0, slash));
    }
    var common = sources.first;
    for (final source in sources.skip(1)) {
      var i = 0;
      while (i < common.length && i < source.length && common[i] == source[i]) {
        i++;
      }
      common = common.substring(0, i);
    }
    final slash = common.lastIndexOf('/');
    return slash < 0 ? '' : common.substring(0, slash + 1);
  }

  /// 虚拟展示路径对应的真实源路径：根层条目即 originalPath，
  /// 条目内部按基准前缀映射，供预览加载与原位置展示使用。
  String _sourceKeyFor(FileItem item, RecycleBinEntry entry) {
    final entryKey = '$_trashPrefix${entry.id}';
    if (item.path == entryKey || item.path == _staticFolder(entryKey)) {
      return entry.originalPath;
    }
    final rel = item.path.startsWith('$_trashPrefix${entry.id}/')
        ? item.path.substring('$_trashPrefix${entry.id}/'.length)
        : item.path;
    return _staticFolder(_entryBase(entry) + rel);
  }

  List<FileItem> _itemsFor(List<RecycleBinEntry> entries) {
    final result = <String, FileItem>{};
    final owners = <String, RecycleBinEntry>{};
    final controller = AppScope.of(context);
    final current = _folder(controller.recycleBinPath);

    void add(String path, String name, bool directory, RecycleBinEntry entry) {
      final canonical = directory ? _folder(path) : path;
      result[canonical] = FileItem(
        path: canonical,
        name: name,
        isDirectory: directory,
        updatedAt: entry.deletedAt,
      );
      owners[canonical] = entry;
    }

    if (current == _rootDir) {
      // 根层平铺：每个删除条目一行，独立展示名与删除时间。
      for (final entry in entries) {
        final directory =
            entry.isDirectory || entry.originalPath.endsWith('/');
        add('$_trashPrefix${entry.id}', entry.name, directory, entry);
      }
    } else if (current.startsWith(_trashPrefix)) {
      // 条目内部：按该条目自己的对象以源路径首段构成虚拟目录树。
      final rest = current.substring(_trashPrefix.length);
      final slash = rest.indexOf('/');
      final id = slash < 0 ? rest : rest.substring(0, slash);
      final entry =
          entries.where((candidate) => candidate.id == id).firstOrNull;
      if (entry != null) {
        final prefix = _staticFolder(_entryBase(entry) +
            current.substring('$_trashPrefix$id/'.length));
        for (final source in entry.objects.keys) {
          if (!source.startsWith(prefix)) continue;
          final relative = source.substring(prefix.length);
          if (relative.isEmpty) continue;
          final nameEnd = relative.indexOf('/');
          final name =
              nameEnd < 0 ? relative : relative.substring(0, nameEnd);
          if (name.isEmpty) continue;
          add('$current$name', name, nameEnd >= 0 || relative.endsWith('/'),
              entry);
        }
      }
    }
    _itemEntries = owners;
    return sortFileItems(result.values, controller.fileSortOption);
  }

  void _open(FileItem item) {
    if (item.isDirectory) {
      AppScope.of(context).setRecycleBinPath(_folder(item.path));
      _selected.value = null;
      return;
    }
    _openPreview(item);
  }

  /// 回收站文件的真实存储位置在条目 payload 下，
  /// 预览按条目内对象路径加载，界面展示仍用原位置。
  void _openPreview(FileItem item) {
    if (item.isDirectory) return;
    if (PreviewTypeResolver.fromFileName(item.name) != PreviewType.image) {
      return;
    }
    final entry = _itemEntries[item.path];
    final tappedTrashPath = entry?.objects[_sourceKeyFor(item, entry!)];
    if (tappedTrashPath == null) return;
    final imageFiles = <FileItem>[];
    final displayPaths = <String, String>{};
    for (final file in _visibleItems) {
      if (file.isDirectory) continue;
      if (PreviewTypeResolver.fromFileName(file.name) != PreviewType.image) {
        continue;
      }
      final fileEntry = _itemEntries[file.path];
      final trashPath =
          fileEntry?.objects[_sourceKeyFor(file, fileEntry!)];
      if (trashPath == null) continue;
      imageFiles.add(
        FileItem(
          path: trashPath,
          name: file.name,
          isDirectory: false,
          updatedAt: file.updatedAt,
        ),
      );
      displayPaths[trashPath] = _sourceKeyFor(file, fileEntry!);
    }
    if (imageFiles.isEmpty) return;
    Navigator.of(context).pushNamed(
      RouteNames.preview,
      arguments: PreviewPageArguments(
        fileName: item.name,
        filePath: tappedTrashPath,
        imageFiles: imageFiles,
        displayPaths: displayPaths,
      ),
    );
  }

  Future<void> _showItemActions(FileItem item) async {
    final entry = _itemEntries[item.path];
    if (entry == null) return;
    final scheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                dense: true,
                title: Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
                subtitle: Text(
                  '${item.typeLabel} · ${_remaining(entry.expiresAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.restore_outlined, size: 22),
                title: const Text('恢复'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _restoreItem(item);
                },
              ),
              ListTile(
                dense: true,
                leading: Icon(Icons.delete_forever_outlined,
                    size: 22, color: scheme.error),
                title: Text('立即删除', style: TextStyle(color: scheme.error)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _purgeItem(item);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _goUp() {
    final controller = AppScope.of(context);
    final up = controller.recycleBinUpPath();
    if (up == controller.recycleBinPath) return;
    controller.setRecycleBinPath(up);
    _selected.value = null;
  }

  Future<void> _restoreItem(FileItem item) async {
    final entry = _itemEntries[item.path];
    if (entry == null) return;
    final controller = AppScope.of(context);
    final confirmed = await AppFeedback.confirm(
      context,
      title: '恢复“${entry.name}”？',
      message: '将恢复至原位置；如名称已被占用，将以“已还原”名称保存。',
      confirmLabel: '恢复',
    );
    if (!confirmed) return;
    try {
      await controller.restoreRecycleBinEntry(entry);
      await _reload();
      if (mounted) AppFeedback.showSnack(context, '已恢复 ${entry.name}');
    } catch (error) {
      if (mounted) AppFeedback.showSnack(context, error.toString());
    }
  }

  Future<void> _purgeItem(FileItem item) async {
    final entry = _itemEntries[item.path];
    if (entry == null) return;
    final controller = AppScope.of(context);
    final confirmed = await AppFeedback.confirm(
      context,
      title: '立即删除“${entry.name}”？',
      message: '将永久删除该项，删除后无法再恢复。',
      confirmLabel: '删除',
    );
    if (!confirmed) return;
    try {
      await controller.purgeRecycleBinEntry(entry);
      _selected.value = null;
      await _reload();
      if (mounted) AppFeedback.showSnack(context, '已永久删除 ${entry.name}');
    } catch (error) {
      if (mounted) AppFeedback.showSnack(context, error.toString());
    }
  }

  String _remaining(DateTime expiresAt) {
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining <= Duration.zero) return '等待 OSS 自动清理';
    if (remaining.inHours < 24) return '约剩余不足 1 天';
    return '约剩余 ${remaining.inDays + 1} 天';
  }

  String _pathLabel(String recycleBinPath, List<RecycleBinEntry> entries) {
    final current = _folder(recycleBinPath);
    if (current == _rootDir) return '回收站';
    if (current.startsWith(_trashPrefix)) {
      final rest = current.substring(_trashPrefix.length);
      final slash = rest.indexOf('/');
      final id = slash < 0 ? rest : rest.substring(0, slash);
      final name = entries
              .where((entry) => entry.id == id)
              .firstOrNull
              ?.name ??
          id;
      final relative = slash < 0 ? '' : rest.substring(slash + 1);
      return relative.isEmpty
          ? '回收站 / $name'
          : '回收站 / $name / $relative';
    }
    return '回收站 / ${current.substring(_rootDir.length)}';
  }

  String _date(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  String _subtitle(FileItem item) {
    final entry = _itemEntries[item.path];
    return entry == null
        ? item.typeLabel
        : '${item.typeLabel} · ${_remaining(entry.expiresAt)}';
  }

  String _metaTime(FileItem item) => _itemEntries[item.path] == null
      ? '—'
      : _date(_itemEntries[item.path]!.deletedAt);

  Widget _itemsArea(List<FileItem> items, AppController controller) {
    if (items.isEmpty) return const Center(child: Text('回收站为空'));
    _visibleItems = items;
    final common = <String, Object?>{
      'selectedPath': _selected.value?.path,
    };
    if (controller.browseMode == BrowseMode.grid) {
      return WorkspaceGridView(
        items: items,
        selectedPath: common['selectedPath'] as String?,
        selectedPaths: const <String>{},
        multiSelecting: false,
        desktop: _desktop,
        thumbnailSize: controller.thumbnailSize,
        subtitleBuilder: _subtitle,
        thumbnailLoader: (_) async => <int>[],
        thumbnailCacheNamespace: 'recycle-bin',
        onOpen: _open,
        onMore: _showItemActions,
        onLongPress: _showItemActions,
        onSelect: (item) => _selected.value = item,
        onToggle: (_) {},
        onMarqueeSelectionChanged: (_) {},
        canUpload: false,
        canDelete: false,
        canDownload: false,
        canMove: false,
        onDownload: (_) {},
        onMove: (_) {},
        onRename: (_) {},
        renamingTarget: null,
        onRenameSubmit: (_, __) async => false,
        onRenameCancel: () {},
        onDelete: (_) {},
        onCreateLink: (_) {},
      );
    }
    return WorkspaceListView(
      items: items,
      desktop: _desktop,
      selectedPath: common['selectedPath'] as String?,
      selectedPaths: const <String>{},
      multiSelecting: false,
      subtitleBuilder: _subtitle,
      metaTimeBuilder: _metaTime,
      canUpload: false,
      canDelete: false,
      canDownload: false,
      canMove: false,
      onOpen: _open,
      onMore: _showItemActions,
      onLongPress: _showItemActions,
      onSelect: (item) => _selected.value = item,
      onToggle: (_) {},
      onMarqueeSelectionChanged: (_) {},
      onPreview: _openPreview,
      onDownload: (_) {},
      onMove: (_) {},
      onRename: (_) {},
      renamingTarget: null,
      onRenameSubmit: (_, __) async => false,
      onRenameCancel: () {},
      onDelete: (_) {},
      onCreateLink: (_) {},
    );
  }

  Widget _details(FileItem? item) {
    final entry = item == null ? null : _itemEntries[item.path];
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          border: Border(left: BorderSide(color: scheme.outlineVariant))),
      child: item == null || entry == null
          ? const Center(child: Text('选中文件后展示详情'))
          : ListView(padding: const EdgeInsets.all(16), children: <Widget>[
              const Text('详情预览', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 20),
              FileTypeIcon(item: item, size: 64),
              const SizedBox(height: 14),
              Text(item.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Text('类型：${item.typeLabel}'),
              Text(
                  '原位置：${AppScope.of(context).displayPath(_sourceKeyFor(item, entry))}'),
              Text('删除于：${_date(entry.deletedAt)}'),
              Text('永久删除：${_date(entry.expiresAt)}'),
              Text(_remaining(entry.expiresAt)),
              const SizedBox(height: 20),
              FilledButton.tonal(
                  onPressed: () => _restoreItem(item), child: const Text('恢复')),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: () => _purgeItem(item),
                style: FilledButton.styleFrom(foregroundColor: scheme.error),
                child: const Text('立即删除'),
              ),
            ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final desktop = _desktop;
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('回收站')),
      body: FutureBuilder<List<RecycleBinEntry>>(
        future: _entriesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('回收站加载失败：${snapshot.error}'));
          }
          final items = _itemsFor(snapshot.data ?? const <RecycleBinEntry>[]);
          final recycleBinPath = controller.recycleBinPath;
          final pathLabel =
              _pathLabel(recycleBinPath, snapshot.data ?? const []);
          if (desktop) {
            return WorkspaceDesktopBody(
              path: pathLabel,
              canGoUp: recycleBinPath != AppController.rootPrefix,
              canUpload: false,
              canDelete: false,
              canDownload: false,
              browseMode: controller.browseMode,
              thumbnailSize: controller.thumbnailSize,
              sortOption: controller.fileSortOption,
              selectedListenable: _selected,
              directorySizeStatesListenable: _directorySizes,
              listArea: _itemsArea(items, controller),
              onGoUp: _goUp,
              onRefresh: _reload,
              onCreateFolder: () {},
              onUpload: () {},
              onUploadDirectory: () {},
              onBrowseModeChanged: controller.setBrowseMode,
              onThumbnailSizeChanged: controller.setThumbnailSize,
              onSortChanged: controller.setFileSortOption,
              onOpen: _open,
              onPreview: _openPreview,
              onDownload: (_) {},
              onDelete: (_) {},
              detailBuilder: _details,
              showPermissionNotice: false,
            );
          }
          return SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(children: <Widget>[
                WorkspaceMobileHeader(
                  title: '回收站',
                  path: pathLabel,
                  roleLabel: controller.session?.displayName ?? '成员',
                  canGoUp: recycleBinPath != AppController.rootPrefix,
                  browseMode: controller.browseMode,
                  sortOption: controller.fileSortOption,
                  onGoUp: _goUp,
                  onRefresh: _reload,
                  onBrowseModeChanged: controller.setBrowseMode,
                  onChooseSort: () => showFileSortSheet(
                    context,
                    current: controller.fileSortOption,
                    onSelected: controller.setFileSortOption,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(child: _itemsArea(items, controller)),
              ]),
            ),
          );
        },
      ),
    );
  }
}
