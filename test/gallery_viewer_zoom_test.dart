import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/shared/widgets/zoomable_image_area.dart';

/// 相册移动端查看器与预览页共用 [ZoomableImageArea]：
/// 这里按查看器语义验证「放大后不切图」与「切图重置缩放」。
void main() {
  Widget viewer({
    required Object resetToken,
    required VoidCallback onSwitch,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(
          child: ZoomableImageArea(
            resetToken: resetToken,
            onSwipe: (velocity, vertical) {
              if (!vertical && velocity.abs() > 120) onSwitch();
            },
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
  }

  double currentScale(WidgetTester tester) {
    final finder = find.byType(InteractiveViewer);
    final viewer = tester.widget<InteractiveViewer>(finder);
    return viewer.transformationController!.value.getMaxScaleOnAxis();
  }

  Future<void> doubleTap(WidgetTester tester) async {
    await tester.tap(find.byType(ZoomableImageArea));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byType(ZoomableImageArea));
    await tester.pumpAndSettle();
  }

  testWidgets('放大状态下水平拖动不切换照片', (tester) async {
    var switches = 0;
    await tester.pumpWidget(viewer(resetToken: 'photo-1', onSwitch: () {
      switches++;
    }));

    await doubleTap(tester);
    expect(currentScale(tester), greaterThan(1));

    await tester.fling(
      find.byType(ZoomableImageArea),
      const Offset(320, 0),
      800,
    );
    await tester.pumpAndSettle();

    expect(switches, 0);
  });

  testWidgets('原始比例下滑动切换并在切图后重置缩放', (tester) async {
    var switches = 0;
    await tester.pumpWidget(viewer(resetToken: 'photo-1', onSwitch: () {
      switches++;
    }));

    await tester.fling(
      find.byType(ZoomableImageArea),
      const Offset(-320, 0),
      800,
    );
    await tester.pumpAndSettle();
    expect(switches, 1);

    await doubleTap(tester);
    expect(currentScale(tester), greaterThan(1));

    await tester.pumpWidget(viewer(resetToken: 'photo-2', onSwitch: () {
      switches++;
    }));
    await tester.pump();

    expect(currentScale(tester), 1);
  });
}
