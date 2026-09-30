import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/router/route_names.dart';
import '../../../core/utils/file_size_formatter.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../application/gallery_controller.dart';
import '../domain/photo_entry.dart';
import '../domain/timeline_group.dart';
import 'gallery_scope.dart';
import 'gallery_viewer_page.dart';

/// 相册时间线页：双端共用实现，桌面端按月分组并支持框选/快捷键，
/// 移动端按天分组并支持长按多选。
class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key, this.desktopChrome = false});

  final bool desktopChrome;

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  bool _loadStarted = false;

  // 框选状态（仅桌面端）。
  final Map<String, GlobalKey> _cellKeys = <String, GlobalKey>{};
  final Set<String> _collapsedGroups = <String>{};
  Rect? _selectionRect;
  Offset? _dragStart;
  bool _dragActive = false;

  @override
  void initState() {
    super.initState();
  }

  void _ensureLoaded(GalleryController controller) {
    if (_loadStarted) return;
    _loadStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = GalleryScope.of(context);
    _ensureLoaded(controller);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget content;
    switch (controller.phase) {
      case GalleryPhase.idle:
      case GalleryPhase.loading:
        content = const Center(child: CircularProgressIndicator());
        break;
      case GalleryPhase.scanning:
        content = _ScanProgressView(controller: controller);
        break;
      case GalleryPhase.error:
        content = _ErrorView(
          message: controller.errorMessage ?? '相册加载失败',
          onRetry: () {
            _loadStarted = false;
            _ensureLoaded(controller);
          },
        );
        break;
      case GalleryPhase.repairing:
      case GalleryPhase.ready:
        content = _buildGalleryBody(context, controller);
        break;
    }

    return Scaffold(
      backgroundColor: widget.desktopChrome ? scheme.surface : null,
      appBar:
          widget.desktopChrome ? null : _MobileAppBar(controller: controller),
      body: Column(
        children: <Widget>[
          if (widget.desktopChrome)
            _DesktopSelectionBar(controller: controller),
          if (controller.phase == GalleryPhase.repairing)
            Material(
              color: scheme.tertiaryContainer,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.onTertiaryContainer,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        controller.repairNotice ?? '照片索引需要修复，正在后台重建…',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(child: content),
          if (widget.desktopChrome) _DesktopStatusLine(controller: controller),
        ],
      ),
      bottomNavigationBar: !widget.desktopChrome && controller.isSelecting
          ? _MobileBatchBar(controller: controller)
          : null,
    );
  }

  Widget _buildGalleryBody(BuildContext context, GalleryController controller) {
    final groups = controller.timelineGroups();
    if (groups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.photo_outlined,
                size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text('相册还是空的', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '上传照片或视频后会自动出现在这里',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }

    _pruneCellKeys(groups);
    final cellExtent =
        widget.desktopChrome ? 170.0 : (MediaQuery.sizeOf(context).width / 3.4);

    final items = <Widget>[
      for (final group in groups) ...<Widget>[
        _GroupHeader(
          group: group,
          collapsed: _collapsedGroups.contains(group.key),
          onToggle: () => setState(() {
            if (!_collapsedGroups.remove(group.key)) {
              _collapsedGroups.add(group.key);
            }
          }),
        ),
        if (!_collapsedGroups.contains(group.key))
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: cellExtent,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
              childAspectRatio: 1,
            ),
            itemCount: group.entries.length,
            itemBuilder: (context, index) {
              final entry = group.entries[index];
              return _PhotoCell(
                controller: controller,
                entry: entry,
                cellKey: _cellKeys.putIfAbsent(entry.key, GlobalKey.new),
                desktop: widget.desktopChrome,
                onTap: () => _onCellTap(controller, entry),
                onLongPress: widget.desktopChrome
                    ? null
                    : () => _onCellLongPress(controller, entry),
              );
            },
          ),
      ],
    ];

    final list = ListView(children: items);

    if (!widget.desktopChrome) return list;

    // 桌面端：包一层 Listener 实现拖拽框选。
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (event) {
              if (event.buttons != kPrimaryMouseButton) return;
              _dragStart = event.position;
              _dragActive = false;
            },
            onPointerMove: (event) {
              final start = _dragStart;
              if (start == null) return;
              if (!_dragActive && (event.position - start).distance < 5) {
                return;
              }
              _dragActive = true;
              final rect = Rect.fromPoints(start, event.position);
              setState(() => _selectionRect = rect);
              controller.replaceSelection(
                _keysIntersecting(rect),
              );
            },
            onPointerUp: (_) {
              _dragStart = null;
              _dragActive = false;
              if (_selectionRect != null) {
                setState(() => _selectionRect = null);
              }
            },
            onPointerCancel: (_) {
              _dragStart = null;
              _dragActive = false;
              if (_selectionRect != null) {
                setState(() => _selectionRect = null);
              }
            },
            child: _DesktopShortcuts(
              controller: controller,
              child: list,
            ),
          ),
        ),
        if (_selectionRect != null)
          Positioned.fromRect(
            rect: _selectionRect!,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 1,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _pruneCellKeys(List<TimelineGroup> groups) {
    final activeKeys = <String>{
      for (final group in groups)
        for (final entry in group.entries) entry.key,
    };
    _cellKeys.removeWhere((key, _) => !activeKeys.contains(key));
  }

  Set<String> _keysIntersecting(Rect rect) {
    final hits = <String>{};
    _cellKeys.forEach((key, cellKey) {
      final context = cellKey.currentContext;
      if (context == null) return;
      final box = context.findRenderObject();
      if (box is! RenderBox) return;
      final cellRect = box.localToGlobal(Offset.zero) & box.size;
      if (cellRect.overlaps(rect)) hits.add(key);
    });
    return hits;
  }

  void _onCellTap(GalleryController controller, PhotoEntry entry) {
    if (!widget.desktopChrome && controller.isSelecting) {
      controller.toggleSelection(entry);
      return;
    }
    if (widget.desktopChrome && HardwareKeyboard.instance.isMetaPressed) {
      controller.toggleSelection(entry);
      return;
    }
    _openViewer(controller, entry);
  }

  void _onCellLongPress(GalleryController controller, PhotoEntry entry) {
    if (controller.selectedKeys.contains(entry.key)) {
      controller.toggleSelection(entry);
      return;
    }
    controller.selectOnly(entry);
  }

  void _openViewer(GalleryController controller, PhotoEntry entry) {
    Navigator.of(context).pushNamed(
      RouteNames.galleryViewer,
      arguments: GalleryViewerArguments(initialKey: entry.key),
    );
  }
}

/// 桌面端快捷键：⌘A 全选、⌘C 复制、⌘V 粘贴上传（界面不展示快捷键说明）。
class _DesktopShortcuts extends StatelessWidget {
  const _DesktopShortcuts({required this.controller, required this.child});

  final GalleryController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
            controller.selectAll,
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () {
          _copy(context);
        },
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            controller.pasteUpload,
      },
      child: Focus(
        autofocus: true,
        child: child,
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final selected = controller.selectedKeys
        .map(controller.entryOfKey)
        .whereType<PhotoEntry>()
        .toList();
    if (selected.isEmpty) return;
    final error = await controller.copyToClipboard(selected);
    if (context.mounted) {
      AppFeedback.showSnack(context, error ?? '已复制 ${selected.length} 张原图到剪贴板');
    }
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.collapsed,
    required this.onToggle,
  });

  final TimelineGroup group;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Text(
              group.label,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${group.entries.length} 张',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            AnimatedRotation(
              turns: collapsed ? -0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(
                Icons.expand_more,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoCell extends StatefulWidget {
  const _PhotoCell({
    required this.controller,
    required this.entry,
    required this.cellKey,
    required this.desktop,
    required this.onTap,
    this.onLongPress,
  });

  final GalleryController controller;
  final PhotoEntry entry;
  final GlobalKey cellKey;
  final bool desktop;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<_PhotoCell> createState() => _PhotoCellState();
}

class _PhotoCellState extends State<_PhotoCell> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return KeyedSubtree(
      key: widget.cellKey,
      child: MouseRegion(
        onEnter:
            widget.desktop ? (_) => setState(() => _hovering = true) : null,
        onExit:
            widget.desktop ? (_) => setState(() => _hovering = false) : null,
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.desktop ? 6 : 2),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: _ThumbnailView(
                      controller: widget.controller, entry: widget.entry),
                ),
                // 云朵角标：有角标 = 原图未缓存本机。
                ValueListenableBuilder<Set<String>>(
                  valueListenable: widget.controller.cachedKeysListenable,
                  builder: (context, cached, _) {
                    if (cached.contains(widget.entry.key)) {
                      return const SizedBox.shrink();
                    }
                    return Positioned(
                      left: 6,
                      bottom: 6,
                      child: _CloudBadge(),
                    );
                  },
                ),
                if (widget.entry.mediaType == PhotoMediaType.video)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Icon(
                        Icons.videocam,
                        size: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ValueListenableBuilder<Set<String>>(
                  valueListenable: widget.controller.selectionListenable,
                  builder: (context, selected, _) {
                    final isSelected = selected.contains(widget.entry.key);
                    final selecting = selected.isNotEmpty;
                    if (!isSelected &&
                        !selecting &&
                        !(_hovering && widget.desktop)) {
                      return const SizedBox.shrink();
                    }
                    return Positioned(
                      top: 6,
                      left: 6,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isSelected
                              ? scheme.primary
                              : Colors.black.withValues(alpha: 0.35),
                          border: isSelected
                              ? null
                              : Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: isSelected
                            ? const Icon(Icons.check,
                                size: 14, color: Colors.white)
                            : null,
                      ),
                    );
                  },
                ),
                ValueListenableBuilder<Set<String>>(
                  valueListenable: widget.controller.selectionListenable,
                  builder: (context, selected, _) {
                    return IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          border: selected.contains(widget.entry.key)
                              ? Border.all(
                                  color: scheme.primary,
                                  width: 2.5,
                                )
                              : null,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThumbnailView extends StatefulWidget {
  const _ThumbnailView({required this.controller, required this.entry});

  final GalleryController controller;
  final PhotoEntry entry;

  @override
  State<_ThumbnailView> createState() => _ThumbnailViewState();
}

class _ThumbnailViewState extends State<_ThumbnailView> {
  late Future<List<int>?> _future;
  String? _fetchedThumbKey;

  @override
  void initState() {
    super.initState();
    _startFetch();
  }

  void _startFetch() {
    _fetchedThumbKey = widget.entry.thumbKey;
    _future = widget.controller.loadGridThumbnail(widget.entry);
  }

  @override
  void didUpdateWidget(covariant _ThumbnailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // key 或缩略图映射变化都重载：存量缩略图补齐完成后，同一 key 的
    // 条目会从"无映射"变为"有映射"，需要重试加载。
    if (oldWidget.entry.key != widget.entry.key ||
        widget.entry.thumbKey != _fetchedThumbKey) {
      _startFetch();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.entry.mediaType == PhotoMediaType.video;
    return FutureBuilder<List<int>?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null && bytes.isNotEmpty) {
          return Image.memory(
            Uint8List.fromList(bytes),
            fit: BoxFit.cover,
            gaplessPlayback: true,
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        // 无缩略图（含无截帧映射的视频）展示占位图。
        return Center(
          child: Icon(
            isVideo ? Icons.videocam_outlined : Icons.image_outlined,
            size: 32,
            color: Theme.of(context).colorScheme.outline,
          ),
        );
      },
    );
  }
}

class _CloudBadge extends StatelessWidget {
  const _CloudBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withValues(alpha: 0.55),
      ),
      child: const Icon(
        Icons.cloud_outlined,
        size: 13,
        color: Colors.white,
      ),
    );
  }
}

class _MobileAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _MobileAppBar({required this.controller});

  final GalleryController controller;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: controller.selectionListenable,
      builder: (context, selected, _) {
        final selecting = selected.isNotEmpty;
        return AppBar(
          leading: selecting
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: controller.clearSelection,
                )
              : null,
          title: Text(selecting ? '已选择 ${selected.length} 张' : '相册'),
          actions: <Widget>[
            if (selecting)
              IconButton(
                tooltip: '全选',
                icon: const Icon(Icons.select_all),
                onPressed: controller.selectAll,
              ),
          ],
        );
      },
    );
  }
}

class _MobileBatchBar extends StatelessWidget {
  const _MobileBatchBar({required this.controller});

  final GalleryController controller;

  @override
  Widget build(BuildContext context) {
    final selected = controller.selectedKeys
        .map(controller.entryOfKey)
        .whereType<PhotoEntry>()
        .toList();
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top:
                BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: <Widget>[
            _BatchAction(
              icon: Icons.download_outlined,
              label: '下载原图',
              onTap: () => controller.downloadOriginals(selected),
            ),
            _BatchAction(
              icon: Icons.share_outlined,
              label: '分享',
              onTap: () => _share(context, selected),
            ),
            _BatchAction(
              icon: Icons.delete_outline,
              label: '删除',
              danger: true,
              onTap: () => _delete(context, selected),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _share(BuildContext context, List<PhotoEntry> selected) async {
    if (selected.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(selected.any((entry) => !controller.isCached(entry.key))
            ? '正在下载原图，完成后自动分享…'
            : '正在准备分享…'),
      ),
    );
    final error = await controller.shareEntries(selected);
    if (error != null) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _delete(BuildContext context, List<PhotoEntry> selected) async {
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除所选照片'),
        content: Text('将 ${selected.length} 张照片和视频移入回收站？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.deleteEntries(selected);
    if (context.mounted) {
      AppFeedback.showSnack(context, '已移入回收站');
    }
  }
}

class _BatchAction extends StatelessWidget {
  const _BatchAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? Theme.of(context).colorScheme.error : null;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopSelectionBar extends StatelessWidget {
  const _DesktopSelectionBar({required this.controller});

  final GalleryController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: controller.selectionListenable,
      builder: (context, selected, _) {
        if (selected.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            border: Border(
              bottom: BorderSide(color: scheme.outlineVariant),
            ),
          ),
          child: Row(
            children: <Widget>[
              Text(
                '已选择 ${selected.length} 张',
                style: theme.textTheme.titleSmall,
              ),
              const Spacer(),
              TextButton(
                onPressed: controller.selectAll,
                child: const Text('全选'),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: controller.clipboardCopiedListenable,
                builder: (context, copied, _) => TextButton(
                  onPressed: () async {
                    final entries = selected
                        .map(controller.entryOfKey)
                        .whereType<PhotoEntry>();
                    final error = await controller.copyToClipboard(entries);
                    if (context.mounted) {
                      AppFeedback.showSnack(
                          context, error ?? '已复制 ${entries.length} 张原图到剪贴板');
                    }
                  },
                  child: Text(copied ? '已复制' : '复制'),
                ),
              ),
              TextButton(
                onPressed: () {
                  controller.downloadOriginals(selected
                      .map(controller.entryOfKey)
                      .whereType<PhotoEntry>());
                },
                child: const Text('下载原图'),
              ),
              TextButton(
                onPressed: () async {
                  final entries = selected
                      .map(controller.entryOfKey)
                      .whereType<PhotoEntry>()
                      .toList();
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('删除所选照片'),
                      content: Text('将 ${entries.length} 张照片和视频移入回收站？'),
                      actions: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('删除'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                  await controller.deleteEntries(entries.toList());
                  if (context.mounted) {
                    AppFeedback.showSnack(context, '已移入回收站');
                  }
                },
                style: TextButton.styleFrom(
                  foregroundColor: scheme.error,
                ),
                child: const Text('删除'),
              ),
              TextButton(
                onPressed: controller.clearSelection,
                child: const Text('取消'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DesktopStatusLine extends StatelessWidget {
  const _DesktopStatusLine({required this.controller});

  final GalleryController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: ValueListenableBuilder<Set<String>>(
        valueListenable: controller.cachedKeysListenable,
        builder: (context, cached, _) {
          final entries = controller.entries;
          final totalBytes =
              entries.fold<int>(0, (sum, entry) => sum + entry.size);
          final uncached = entries.where((e) => !cached.contains(e.key)).length;
          return Text(
            '共 ${entries.length} 张照片和视频 · 已用空间 '
            '${FileSizeFormatter.format(totalBytes)}'
            '${uncached > 0 ? ' · 其中 $uncached 张原图未缓存到本机' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
        },
      ),
    );
  }
}

class _ScanProgressView extends StatelessWidget {
  const _ScanProgressView({required this.controller});

  final GalleryController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ValueListenableBuilder<(int, int)?>(
        valueListenable: controller.scanProgressListenable,
        builder: (context, progress, _) {
          final total = progress?.$2 ?? 0;
          final processed = progress?.$1 ?? 0;
          final ratio = total > 0 ? processed / total : 0.0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 48,
                height: 48,
                child: total > 0
                    ? CircularProgressIndicator(value: ratio)
                    : const CircularProgressIndicator(),
              ),
              const SizedBox(height: 16),
              Text(
                '正在建立照片索引…',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                total > 0 ? '已处理 $processed / $total 张' : '正在扫描网盘中的照片和视频',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.cloud_off_outlined,
              size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(message, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
