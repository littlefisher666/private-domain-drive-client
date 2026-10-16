import 'package:flutter/material.dart';

/// 桌面端拖拽多选的选框画笔：半透明填充 + 描边。
class SelectionRectanglePainter extends CustomPainter {
  const SelectionRectanglePainter(this.rect, this.color);

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
  bool shouldRepaint(covariant SelectionRectanglePainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.color != color;
}
