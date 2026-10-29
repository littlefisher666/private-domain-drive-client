import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/router/route_names.dart';
import '../../../shared/state/app_services.dart';
import '../../../shared/path_utils.dart' as path_utils;
import '../application/workspace_controller.dart';
import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/file_icon.dart';
import '../../../shared/widgets/file_sort_sheet.dart';
import '../../preview/domain/preview_type.dart';
import '../../preview/presentation/preview_page.dart';
import '../domain/file_item.dart';
import '../domain/recycle_bin_batch_result.dart';
import '../domain/recycle_bin_entry.dart';
import 'widgets/recycle_bin_batch_bar.dart';
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
  final Set<String> _multiSelected = <String>{};
  bool _multiSelecting = false;
  bool _batchBusy = false;
  final ValueNotifier<({String label, int processed, int total})?>
      _batchProgress =
      ValueNotifier<({String label, int processed, int total})?>(null);

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
    _batchProgress.dispose();
    super.dispose();
  }

  bool get _atRoot {
    final controller = AppScope.read(context);
    return _folder(controller.recycleBinController.recycleBinPath) == _rootDir;
  }

  Future<List<RecycleBinEntry>> _load() async {
    final entries = await AppScope.of(context).recycleBinController.listRecycleBin();
    if (mounted) setState(() {});
    return entries;
  }

  Future<void> _reload() async {
    final previous = _entriesFuture;
    final future = _load();
    setState(() {
      _entriesFuture = future;
    });
    try {
      await future;
    } catch (error, stackTrace) {
      if (!mounted) return;
      // 刷新失败时回退到已展示的条目，仅给出提示，不替换为错误页。
      setState(() {
        _entriesFuture = previous;
      });
      AppFeedback.showError(context, error, stackTrace);
    }
  }

  String _folder(String path) => path.endsWith('/') ? path : '$path/';

  static final String _rootDir = _staticFolder(path_utils.rootPrefix);
  static final String _trashPrefix =
      _staticFolder('${path_utils.rootPrefix}.trash');

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
    final current = _folder(controller.recycleBinController.recycleBinPath);

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
    return sortFileItems(result.values, controller.workspaceController.fileSortOption);
  }

  void _enterMultiSelect(FileItem item) {
    setState(() {
      _multiSelecting = true;
      _multiSelected
        ..clear()
        ..add(item.path);
    });
  }

  void _toggleSelection(FileItem item) {
    setState(() {
      if (_multiSelected.remove(item.path)) {
        if (_multiSelected.isEmpty) _multiSelecting = false;
      } else {
        _multiSelected.add(item.path);
        _multiSelecting = true;
      }
    });
  }

  void _clearSelection() {
    if (_multiSelected.isEmpty && !_multiSelecting) return;
    setState(() {
      _multiSelected.clear();
      _multiSelecting = false;
    });
  }

  void _onSelect(FileItem item) {
    if (_atRoot) {
      final modifier = HardwareKeyboard.instance.isMetaPressed ||
          HardwareKeyboard.instance.isControlPressed;
      if (_multiSelecting || (_desktop && modifier)) {
        _toggleSelection(item);
        return;
      }
    }
    _selected.value = item;
  }

  void _onLongPress(FileItem item) {
    if (_atRoot) {
      _enterMultiSelect(item);
      return;
    }
    _showItemActions(item);
  }

  List<RecycleBinEntry> _selectedEntries() {
    final entries = <String, RecycleBinEntry>{};
    for (final path in _multiSelected) {
      final entry = _itemEntries[path];
      if (entry != null) entries[entry.id] = entry;
    }
    return entries.values.toList(growable: false);
  }

  void _startBatch(String label, int total) {
    setState(() => _batchBusy = true);
    _batchProgress.value = (label: label, processed: 0, total: total);
  }

  void _finishBatch() {
    if (!mounted) return;
    setState(() => _batchBusy = false);
    _batchProgress.value = null;
  }

  Future<void> _restoreSelected() async {
    final entries = _selectedEntries();
    if (entries.isEmpty || _batchBusy) return;
    final confirmed = await AppFeedback.confirm(
      context,
      title: '恢复选中的 ${entries.length} 个条目？',
      message: '将恢复到各自原位置；如名称已被占用，将以“已还原”名称保存。',
      confirmLabel: '恢复',
    );
    if (!confirmed || !mounted) return;
    _startBatch('恢复', entries.length);
    final controller = AppScope.read(context).recycleBinController;
    try {
      final result = await controller.restoreRecycleBinEntries(
        entries,
        onProgress: (processed, total) {
          _batchProgress.value = (label: '恢复', processed: processed, total: total);
        },
      );
      _clearSelection();
      await _reload();
      if (mounted) {
        AppFeedback.showSnack(
          context,
          _batchSummary('恢复', result),
        );
      }
    } catch (error, stackTrace) {
      if (mounted) AppFeedback.showError(context, error, stackTrace);
    } finally {
      _finishBatch();
    }
  }

  Future<void> _purgeSelected() async {
    final entries = _selectedEntries();
    if (entries.isEmpty || _batchBusy) return;
    final confirmed = await AppFeedback.confirm(
      context,
      title: '立即删除选中的 ${entries.length} 个条目？',
      message: '将永久删除这 ${entries.length} 个条目，删除后无法再恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _purgeEntries(entries);
  }

  Future<void> _clearRecycleBin() async {
    if (_batchBusy) return;
    final count = _itemEntries.length;
    if (count == 0) return;
    final confirmed = await AppFeedback.confirm(
      context,
      title: '清空回收站？',
      message: '将永久删除回收站内的全部 $count 个条目，删除后无法再恢复。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _purgeEntries(_itemEntries.values.toList(growable: false));
  }

  Future<void> _purgeEntries(List<RecycleBinEntry> entries) async {
    if (entries.isEmpty) return;
    _startBatch('删除', entries.length);
    final controller = AppScope.read(context).recycleBinController;
    try {
      final result = await controller.purgeRecycleBinEntries(
        entries,
        onProgress: (processed, total) {
          _batchProgress.value = (label: '删除', processed: processed, total: total);
        },
      );
      _clearSelection();
      await _reload();
      if (mounted) {
        AppFeedback.showSnack(context, _batchSummary('删除', result));
      }
    } catch (error, stackTrace) {
      if (mounted) AppFeedback.showError(context, error, stackTrace);
    } finally {
      _finishBatch();
    }
  }

  String _batchSummary(String action, RecycleBinBatchResult result) {
    if (result.failureCount == 0) {
      return '已$action ${result.successCount} 个条目';
    }
    return '已$action ${result.successCount} 个条目，${result.failureCount} 个失败，失败条目保留在回收站';
  }

  void _open(FileItem item) {
    if (item.isDirectory) {
      _clearSelection();
      AppScope.of(context).recycleBinController.setRecycleBinPath(_folder(item.path));
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
    final tappedTrashPath = entry?.objects[_sourceKeyFor(item, entry)];
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
          fileEntry?.objects[_sourceKeyFor(file, fileEntry)];
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
    final up = controller.recycleBinController.recycleBinUpPath();
    if (up == controller.recycleBinController.recycleBinPath) return;
    _clearSelection();
    controller.recycleBinController.setRecycleBinPath(up);
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
      await controller.recycleBinController.restoreRecycleBinEntry(entry);
      await _reload();
      if (mounted) AppFeedback.showSnack(context, '已恢复 ${entry.name}');
    } catch (error, stackTrace) {
      if (mounted) AppFeedback.showError(context, error, stackTrace);
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
      await controller.recycleBinController.purgeRecycleBinEntry(entry);
      _selected.value = null;
      await _reload();
      if (mounted) AppFeedback.showSnack(context, '已永久删除 ${entry.name}');
    } catch (error, stackTrace) {
      if (mounted) AppFeedback.showError(context, error, stackTrace);
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

  Widget _itemsArea(List<FileItem> items, AppServices controller) {
    if (items.isEmpty) {
      if (_desktop) return const Center(child: Text('回收站为空'));
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const <Widget>[
            SizedBox(height: 160),
            Center(child: Text('回收站为空')),
          ],
        ),
      );
    }
    _visibleItems = items;
    final root =
        _folder(controller.recycleBinController.recycleBinPath) == _rootDir;
    final selectedPath = _selected.value?.path;
    final selectedPaths =
        root ? Set<String>.unmodifiable(_multiSelected) : const <String>{};
    final multiSelecting = root && _multiSelecting;
    void onMarqueeSelectionChanged(Set<String> paths) {
      if (!root) return;
      setState(() {
        _multiSelected
          ..clear()
          ..addAll(paths);
        _multiSelecting = paths.isNotEmpty;
      });
    }

    final Widget list = controller.workspaceController.browseMode ==
            BrowseMode.grid
        ? WorkspaceGridView(
            items: items,
            selectedPath: selectedPath,
            selectedPaths: selectedPaths,
            multiSelecting: multiSelecting,
            desktop: _desktop,
            thumbnailSize: controller.workspaceController.thumbnailSize,
            subtitleBuilder: _subtitle,
            thumbnailLoader: (_) async => <int>[],
            thumbnailCacheNamespace: 'recycle-bin',
            onOpen: _open,
            onMore: _showItemActions,
            onLongPress: _onLongPress,
            onSelect: _onSelect,
            onToggle: _toggleSelection,
            onMarqueeSelectionChanged: onMarqueeSelectionChanged,
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
          )
        : WorkspaceListView(
            items: items,
            desktop: _desktop,
            selectedPath: selectedPath,
            selectedPaths: selectedPaths,
            multiSelecting: multiSelecting,
            subtitleBuilder: _subtitle,
            metaTimeBuilder: _metaTime,
            canUpload: false,
            canDelete: false,
            canDownload: false,
            canMove: false,
            onOpen: _open,
            onMore: _showItemActions,
            onLongPress: _onLongPress,
            onSelect: _onSelect,
            onToggle: _toggleSelection,
            onMarqueeSelectionChanged: onMarqueeSelectionChanged,
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
    final refreshableList =
        _desktop ? list : RefreshIndicator(onRefresh: _reload, child: list);
    if (!root) return refreshableList;

    final showBar = _desktop || _multiSelecting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ValueListenableBuilder<({String label, int processed, int total})?>(
          valueListenable: _batchProgress,
          builder: (context, progress, _) {
            if (progress == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _BatchProgressBanner(progress: progress),
            );
          },
        ),
        if (showBar || !_multiSelecting)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: <Widget>[
                if (showBar)
                  Expanded(
                    child: RecycleBinBatchBar(
                      selectedCount: _multiSelected.length,
                      itemCount: items.length,
                      busy: _batchBusy,
                      onSelectAll: () {
                        setState(() {
                          if (_multiSelected.length == items.length) {
                            _multiSelected.clear();
                            _multiSelecting = false;
                          } else {
                            _multiSelected
                              ..clear()
                              ..addAll(items.map((item) => item.path));
                            _multiSelecting = true;
                          }
                        });
                      },
                      onClearSelection: _clearSelection,
                      onRestore: _restoreSelected,
                      onPurge: _purgeSelected,
                    ),
                  )
                else
                  const Spacer(),
                if (!_multiSelecting) ...<Widget>[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed:
                        (!_batchBusy && items.isNotEmpty) ? _clearRecycleBin : null,
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                    label: const Text('清空回收站'),
                  ),
                ],
              ],
            ),
          ),
        Expanded(child: refreshableList),
      ],
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
                  '原位置：${AppScope.of(context).workspaceController.displayPath(_sourceKeyFor(item, entry))}'),
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
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text('回收站加载失败，请稍后重试'),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _reload, child: const Text('重试')),
                ],
              ),
            );
          }
          final items = _itemsFor(snapshot.data ?? const <RecycleBinEntry>[]);
          final recycleBinPath = controller.recycleBinController.recycleBinPath;
          final pathLabel =
              _pathLabel(recycleBinPath, snapshot.data ?? const []);
          if (desktop) {
            return WorkspaceDesktopBody(
              path: pathLabel,
              canGoUp: recycleBinPath != path_utils.rootPrefix,
              canUpload: false,
              canDelete: false,
              canDownload: false,
              browseMode: controller.workspaceController.browseMode,
              thumbnailSize: controller.workspaceController.thumbnailSize,
              sortOption: controller.workspaceController.fileSortOption,
              selectedListenable: _selected,
              directorySizeStatesListenable: _directorySizes,
              listArea: _itemsArea(items, controller),
              onGoUp: _goUp,
              onRefresh: _reload,
              onCreateFolder: () {},
              onUpload: () {},
              onUploadDirectory: () {},
              onBrowseModeChanged: controller.workspaceController.setBrowseMode,
              onThumbnailSizeChanged: controller.workspaceController.setThumbnailSize,
              onSortChanged: controller.workspaceController.setFileSortOption,
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
                  roleLabel: controller.sessionController.session?.displayName ?? '成员',
                  canGoUp: recycleBinPath != path_utils.rootPrefix,
                  browseMode: controller.workspaceController.browseMode,
                  sortOption: controller.workspaceController.fileSortOption,
                  onGoUp: _goUp,
                  onRefresh: _reload,
                  onBrowseModeChanged: controller.workspaceController.setBrowseMode,
                  onChooseSort: () => showFileSortSheet(
                    context,
                    current: controller.workspaceController.fileSortOption,
                    onSelected: controller.workspaceController.setFileSortOption,
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

class _BatchProgressBanner extends StatelessWidget {
  const _BatchProgressBanner({required this.progress});

  final ({String label, int processed, int total}) progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '正在${progress.label} ${progress.processed}/${progress.total} 个条目…',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
