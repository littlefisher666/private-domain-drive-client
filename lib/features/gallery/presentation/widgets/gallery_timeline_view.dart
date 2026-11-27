import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../domain/timeline_group.dart';
import 'gallery_page_group_header.dart';

const double _cellSpacing = 2;
const EdgeInsets _gridPadding =
    EdgeInsets.symmetric(horizontal: 3, vertical: 3);

/// 相册时间线：分组标题 + 懒构建网格。
///
/// 每个未折叠分组对应一个标题 sliver 与一个网格 sliver。滚动视图会
/// layout 视口内的所有 sliver，而 `RenderSliverGrid` 在完全离开预取
/// 窗口时仍会构建首格，因此网格外包一层 [SliverLayoutBuilder]：离开
/// 「视口 + 预取窗口」时只渲染与真实网格滚动范围等高的占位 sliver，
/// 进入预取窗口后才构建真实 [SliverGrid]。
class GalleryTimelineView extends StatelessWidget {
  const GalleryTimelineView({
    super.key,
    required this.groups,
    required this.collapsedGroups,
    required this.onToggleGroup,
    required this.cellExtent,
    required this.cellBuilder,
  });

  final List<TimelineGroup> groups;
  final Set<String> collapsedGroups;
  final ValueChanged<TimelineGroup> onToggleGroup;
  final double cellExtent;
  final Widget Function(BuildContext context, TimelineGroup group, int index)
      cellBuilder;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: <Widget>[
        for (final group in groups) ...<Widget>[
          SliverToBoxAdapter(
            child: GalleryPageGroupHeader(
              group: group,
              collapsed: collapsedGroups.contains(group.key),
              onToggle: () => onToggleGroup(group),
            ),
          ),
          if (!collapsedGroups.contains(group.key))
            SliverPadding(
              padding: _gridPadding,
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final delegate =
                      SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: cellExtent,
                    mainAxisSpacing: _cellSpacing,
                    crossAxisSpacing: _cellSpacing,
                    childAspectRatio: 1,
                  );
                  if (_isOutsideCacheWindow(constraints)) {
                    return SliverToBoxAdapter(
                      child: SizedBox(
                        height: _gridExtent(
                          delegate,
                          constraints,
                          group.entries.length,
                        ),
                      ),
                    );
                  }
                  return SliverGrid(
                    gridDelegate: delegate,
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => cellBuilder(context, group, index),
                      childCount: group.entries.length,
                      addAutomaticKeepAlives: false,
                    ),
                  );
                },
              ),
            ),
        ],
      ],
    );
  }

  /// 网格完全离开「视口 + 预取窗口」：此时不构建任何格子。
  /// 上下两个方向都依赖该判断（滚过头的分组 remainingPaintExtent 为 0，
  /// 未到达的分组 remainingCacheExtent 为 0）。
  bool _isOutsideCacheWindow(SliverConstraints constraints) {
    return constraints.remainingPaintExtent <= 0 &&
        constraints.remainingCacheExtent <= 0;
  }

  /// 与真实网格完全一致的滚动范围：用同一 delegate 和当前 constraints
  /// 取最后一个格子的几何，`scrollOffset + mainAxisExtent` 等于
  /// `SliverGrid` 的 scrollExtent。
  double _gridExtent(
    SliverGridDelegate delegate,
    SliverConstraints constraints,
    int childCount,
  ) {
    if (childCount == 0) return 0;
    final layout = delegate.getLayout(constraints);
    final last = layout.getGeometryForChildIndex(childCount - 1);
    return last.scrollOffset + last.mainAxisExtent;
  }
}