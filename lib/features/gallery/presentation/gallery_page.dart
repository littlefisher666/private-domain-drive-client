import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/router/route_names.dart';
import '../application/gallery_controller.dart';
import '../domain/photo_entry.dart';
import '../domain/timeline_group.dart';
import 'gallery_scope.dart';
import 'gallery_viewer_page.dart';
import 'widgets/gallery_page_desktop_selection_bar.dart';
import 'widgets/gallery_page_desktop_shortcuts.dart';
import 'widgets/gallery_page_desktop_status_line.dart';
import 'widgets/gallery_page_error_view.dart';
import 'widgets/gallery_page_group_header.dart';
import 'widgets/gallery_page_mobile_app_bar.dart';
import 'widgets/gallery_page_mobile_batch_bar.dart';
import 'widgets/gallery_page_photo_cell.dart';
import 'widgets/gallery_page_scan_progress_view.dart';

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
        content = GalleryPageScanProgressView(controller: controller);
        break;
      case GalleryPhase.error:
        content = GalleryPageErrorView(
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
          widget.desktopChrome ? null : GalleryPageMobileAppBar(controller: controller),
      body: Column(
        children: <Widget>[
          if (widget.desktopChrome)
            GalleryPageDesktopSelectionBar(controller: controller),
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
          if (widget.desktopChrome) GalleryPageDesktopStatusLine(controller: controller),
        ],
      ),
      bottomNavigationBar: !widget.desktopChrome && controller.isSelecting
          ? GalleryPageMobileBatchBar(controller: controller)
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
        GalleryPageGroupHeader(
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
              return GalleryPagePhotoCell(
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
            child: GalleryPageDesktopShortcuts(
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
