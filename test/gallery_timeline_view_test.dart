import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/gallery/domain/photo_entry.dart';
import 'package:private_domain_drive_client/features/gallery/domain/timeline_group.dart';
import 'package:private_domain_drive_client/features/gallery/presentation/widgets/gallery_timeline_view.dart';

const double _cellExtent = 100;

/// 构造 10 个分组、每组 12 条的假时间线，格子总数远大于首屏容量。
List<TimelineGroup> _groups() {
  return <TimelineGroup>[
    for (var day = 1; day <= 10; day++)
      TimelineGroup(
        key: '2026-10-$day',
        label: '10月$day日',
        start: DateTime(2026, 10, day),
        entries: <PhotoEntry>[
          for (var index = 0; index < 12; index++)
            PhotoEntry(
              key: 'g$day-$index',
              mediaType: PhotoMediaType.image,
              takenAt: DateTime(2026, 10, day, 12, index),
              size: 1024,
              directory: 'shared/相册/',
            ),
        ],
      ),
  ];
}

int _groupIndex(String cellKey) =>
    int.parse(cellKey.substring(1).split('-').first);

Set<int> _mountedGroups(Set<String> mounted) =>
    mounted.map(_groupIndex).toSet();

/// 记录当前仍挂载的格子：initState 加入、dispose 移除，
/// 可直接断言「某分组构建格子数为 0」。
class _TrackedCell extends StatefulWidget {
  const _TrackedCell({required this.cellKey, required this.mounted});

  final String cellKey;
  final Set<String> mounted;

  @override
  State<_TrackedCell> createState() => _TrackedCellState();
}

class _TrackedCellState extends State<_TrackedCell> {
  @override
  void initState() {
    super.initState();
    widget.mounted.add(widget.cellKey);
  }

  @override
  void didUpdateWidget(covariant _TrackedCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cellKey != widget.cellKey) {
      widget.mounted
        ..remove(oldWidget.cellKey)
        ..add(widget.cellKey);
    }
  }

  @override
  void dispose() {
    widget.mounted.remove(widget.cellKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

Future<void> _pumpTimeline(
  WidgetTester tester,
  Set<String> mounted, {
  Set<String> collapsed = const <String>{},
  double textScale = 1,
  Size size = const Size(400, 400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: GalleryTimelineView(
          groups: _groups(),
          collapsedGroups: collapsed,
          onToggleGroup: (_) {},
          cellExtent: _cellExtent,
          cellBuilder: (context, group, index) => _TrackedCell(
            cellKey: group.entries[index].key,
            mounted: mounted,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable)).position;

void main() {
  testWidgets('首帧只构建视口与预取窗口内的分组，窗口外分组格子数为 0',
      (tester) async {
    final mounted = <String>{};
    await _pumpTimeline(tester, mounted);

    final groups = _mountedGroups(mounted);
    expect(groups, contains(1));
    expect(groups, contains(2));
    // 视口 400 + 预取 250 只能覆盖前两个分组，其余分组必须为 0 格。
    expect(groups.where((group) => group >= 4), isEmpty);
    expect(mounted, isNotEmpty);
    expect(mounted.length, lessThan(120));
  });

  testWidgets('向上滚动后，视口上方的远距离分组格子数为 0', (tester) async {
    final mounted = <String>{};
    await _pumpTimeline(tester, mounted);

    final position = _position(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();

    final groups = _mountedGroups(mounted);
    expect(groups, contains(10));
    expect(groups.where((group) => group <= 7), isEmpty);
  });

  testWidgets('滚动进入预取窗口后分组才构建格子', (tester) async {
    final mounted = <String>{};
    await _pumpTimeline(tester, mounted);
    expect(_mountedGroups(mounted), isNot(contains(10)));

    final position = _position(tester);
    final viewportHeight =
        tester.getSize(find.byType(GalleryTimelineView)).height;
    // 逐步滚到底部，找到末尾分组刚进入预取窗口的位置。
    var offset = 0.0;
    while (!_mountedGroups(mounted).contains(10) &&
        offset < position.maxScrollExtent) {
      offset += 50;
      position.jumpTo(offset.clamp(0, position.maxScrollExtent));
      await tester.pump();
    }

    final groups = _mountedGroups(mounted);
    expect(groups, contains(10));
    expect(groups, isNot(contains(1)));
    // 此时末尾分组仍在视口下方：已预取但尚未可见。
    final lastGroupCells = find.byWidgetPredicate(
      (widget) => widget is _TrackedCell && widget.cellKey.startsWith('g10-'),
      skipOffstage: false,
    );
    expect(lastGroupCells, findsWidgets);
    expect(tester.getTopLeft(lastGroupCells.first).dy,
        greaterThanOrEqualTo(viewportHeight - 1));
  });

  testWidgets('占位与真实网格的滚动范围一致（多位置与文字缩放）',
      (tester) async {
    final mounted = <String>{};
    await _pumpTimeline(tester, mounted, textScale: 1.4);

    final position = _position(tester);
    final atTop = position.maxScrollExtent;
    expect(atTop, greaterThan(0));

    position.jumpTo(atTop * 0.45);
    await tester.pumpAndSettle();
    final atMiddle = position.maxScrollExtent;

    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final atBottom = position.maxScrollExtent;

    position.jumpTo(0);
    await tester.pumpAndSettle();
    final backToTop = position.maxScrollExtent;

    // 同一分组在占位/真实网格之间切换后，总滚动范围保持不变。
    expect(atMiddle, moreOrLessEquals(atTop, epsilon: 0.01));
    expect(atBottom, moreOrLessEquals(atTop, epsilon: 0.01));
    expect(backToTop, moreOrLessEquals(atTop, epsilon: 0.01));
  });

  testWidgets('折叠分组不构建其格子', (tester) async {
    final mounted = <String>{};
    await _pumpTimeline(
      tester,
      mounted,
      collapsed: const <String>{'2026-10-1'},
    );

    final groups = _mountedGroups(mounted);
    expect(groups, isNot(contains(1)));
    expect(groups, contains(2));
  });
}