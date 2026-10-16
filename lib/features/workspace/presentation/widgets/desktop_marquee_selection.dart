import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/file_item.dart';
import 'selection_rectangle_painter.dart';

/// 桌面端在文件区域拖拽时绘制选框，并将与选框相交的可见条目交给
/// 既有的多选状态管理。普通点击不会越过拖拽阈值，因此不影响单击、双击。
class DesktopMarqueeSelection extends StatefulWidget {
  const DesktopMarqueeSelection({
    super.key,
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
  State<DesktopMarqueeSelection> createState() =>
      _DesktopMarqueeSelectionState();
}

class _DesktopMarqueeSelectionState extends State<DesktopMarqueeSelection> {
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
                painter: SelectionRectanglePainter(
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
