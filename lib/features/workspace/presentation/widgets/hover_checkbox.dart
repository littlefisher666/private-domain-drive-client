import 'package:flutter/material.dart';

/// 悬停时才显示的多选复选框。
class HoverCheckbox extends StatefulWidget {
  const HoverCheckbox({super.key, required this.value, required this.onChanged});

  final bool value;
  final VoidCallback onChanged;

  @override
  State<HoverCheckbox> createState() => _HoverCheckboxState();
}

class _HoverCheckboxState extends State<HoverCheckbox> {
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
