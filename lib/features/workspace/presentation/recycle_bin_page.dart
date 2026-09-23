import 'package:flutter/material.dart';

import '../../../shared/state/app_controller.dart';
import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/file_icon.dart';
import '../../../shared/widgets/file_sort_sheet.dart';
import '../domain/file_item.dart';
import '../domain/recycle_bin_entry.dart';
import 'workspace_page.dart';

/// 复用共享空间浏览器外壳，并以删除批次组成虚拟目录树。
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
  String _currentPath = AppController.rootPrefix;
  Map<String, RecycleBinEntry> _itemEntries = <String, RecycleBinEntry>{};

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

  List<FileItem> _itemsFor(List<RecycleBinEntry> entries) {
    final result = <String, FileItem>{};
    final owners = <String, RecycleBinEntry>{};
    final current = _folder(_currentPath);

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

    for (final entry in entries) {
      // 目录条目按其 payload 对象展开；文件条目本身就是一个可列出项。
      // 两者统一按“源路径的第一段”构成虚拟目录树，避免逐个删除的文件
      // 聚合出的虚拟文件夹在进入后为空。
      final sources = entry.isDirectory
          ? entry.objects.keys
          : <String>[entry.originalPath];
      for (final source in sources) {
        if (!source.startsWith(current)) continue;
        final relative = source.substring(current.length);
        if (relative.isEmpty) continue;
        final slash = relative.indexOf('/');
        final name = slash < 0 ? relative : relative.substring(0, slash);
        if (name.isEmpty) continue;
        add('$current$name', name, slash >= 0 || relative.endsWith('/'), entry);
      }
    }
    _itemEntries = owners;
    return sortFileItems(result.values, AppScope.of(context).fileSortOption);
  }

  void _open(FileItem item) {
    if (!item.isDirectory) return;
    setState(() {
      _currentPath = _folder(item.path);
      _selected.value = null;
    });
  }

  void _goUp() {
    if (_currentPath == AppController.rootPrefix) return;
    final path = _currentPath.substring(0, _currentPath.length - 1);
    final slash = path.lastIndexOf('/');
    setState(() {
      _currentPath = slash < AppController.rootPrefix.length
          ? AppController.rootPrefix
          : path.substring(0, slash + 1);
      _selected.value = null;
    });
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
      message: '将永久删除该批次，删除后无法再恢复。',
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

  String _date(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  String _subtitle(FileItem item) {
    final entry = _itemEntries[item.path];
    return entry == null ? item.typeLabel : '${item.typeLabel} · ${_remaining(entry.expiresAt)}';
  }

  String _metaTime(FileItem item) =>
      _itemEntries[item.path] == null ? '—' : _date(_itemEntries[item.path]!.deletedAt);

  Widget _itemsArea(List<FileItem> items, AppController controller) {
    if (items.isEmpty) return const Center(child: Text('回收站为空'));
    final common = <String, Object?>{
      'selectedPath': _selected.value?.path,
    };
    if (controller.browseMode == BrowseMode.grid) {
      return WorkspaceGridView(
        items: items,
        selectedPath: common['selectedPath'] as String?,
        selectedPaths: const <String>{}, multiSelecting: false, desktop: _desktop,
        thumbnailSize: controller.thumbnailSize, subtitleBuilder: _subtitle,
        thumbnailLoader: (_) async => <int>[], thumbnailCacheNamespace: 'recycle-bin',
        onOpen: _open, onMore: _restoreItem,
        onSelect: (item) => _selected.value = item, onToggle: (_) {},
        onMarqueeSelectionChanged: (_) {}, canUpload: false, canDelete: false,
        canDownload: false, onDownload: (_) {}, onRename: (_) {}, renamingPath: null,
        onRenameSubmit: (_, __) async => false, onRenameCancel: () {}, onDelete: (_) {},
      );
    }
    return WorkspaceListView(
      items: items, desktop: _desktop, selectedPath: common['selectedPath'] as String?,
      selectedPaths: const <String>{}, multiSelecting: false, subtitleBuilder: _subtitle,
      metaTimeBuilder: _metaTime, canUpload: false, canDelete: false, canDownload: false,
      onOpen: _open, onMore: _restoreItem, onSelect: (item) => _selected.value = item,
      onToggle: (_) {}, onMarqueeSelectionChanged: (_) {}, onPreview: (_) {},
      onDownload: (_) {}, onRename: (_) {}, renamingPath: null,
      onRenameSubmit: (_, __) async => false, onRenameCancel: () {}, onDelete: (_) {},
    );
  }

  Widget _details(FileItem? item) {
    final entry = item == null ? null : _itemEntries[item.path];
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest,
          border: Border(left: BorderSide(color: scheme.outlineVariant))),
      child: item == null || entry == null
          ? const Center(child: Text('选中文件后展示详情'))
          : ListView(padding: const EdgeInsets.all(16), children: <Widget>[
              const Text('详情预览', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 20), FileTypeIcon(item: item, size: 64),
              const SizedBox(height: 14), Text(item.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12), Text('类型：${item.typeLabel}'),
              Text('原位置：${AppScope.of(context).displayPath(entry.originalPath)}'),
              Text('删除于：${_date(entry.deletedAt)}'), Text('永久删除：${_date(entry.expiresAt)}'),
              Text(_remaining(entry.expiresAt)), const SizedBox(height: 20),
              FilledButton.tonal(onPressed: () => _restoreItem(item), child: const Text('恢复')),
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
          if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return Center(child: Text('回收站加载失败：${snapshot.error}'));
          final items = _itemsFor(snapshot.data ?? const <RecycleBinEntry>[]);
          final pathLabel = _currentPath == AppController.rootPrefix
              ? '回收站' : '回收站 / ${_currentPath.substring(AppController.rootPrefix.length)}';
          if (desktop) {
            return WorkspaceDesktopBody(
              path: pathLabel, canGoUp: _currentPath != AppController.rootPrefix,
              canUpload: false, canDelete: false, canDownload: false,
              browseMode: controller.browseMode, thumbnailSize: controller.thumbnailSize,
              sortOption: controller.fileSortOption, selectedListenable: _selected,
              directorySizeStatesListenable: _directorySizes, listArea: _itemsArea(items, controller),
              onGoUp: _goUp, onRefresh: _reload, onCreateFolder: () {}, onUpload: () {}, onUploadDirectory: () {},
              onBrowseModeChanged: controller.setBrowseMode, onThumbnailSizeChanged: controller.setThumbnailSize,
              onSortChanged: controller.setFileSortOption, onOpen: _open, onPreview: (_) {}, onDownload: (_) {}, onDelete: (_) {},
              detailBuilder: _details, showPermissionNotice: false,
            );
          }
          return SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(children: <Widget>[
                WorkspaceMobileHeader(
                  title: '回收站', path: pathLabel, roleLabel: controller.session?.displayName ?? '成员',
                  canGoUp: _currentPath != AppController.rootPrefix, browseMode: controller.browseMode,
                  thumbnailSize: controller.thumbnailSize, sortOption: controller.fileSortOption,
                  onGoUp: _goUp, onRefresh: _reload, onBrowseModeChanged: controller.setBrowseMode,
                  onThumbnailSizeChanged: controller.setThumbnailSize,
                  onChooseSort: () => showFileSortSheet(
                    context,
                    current: controller.fileSortOption,
                    onSelected: controller.setFileSortOption,
                  ),
                ),
                const SizedBox(height: 12), Expanded(child: _itemsArea(items, controller)),
              ]),
            ),
          );
        },
      ),
    );
  }
}
