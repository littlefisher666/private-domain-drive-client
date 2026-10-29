import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/shared/widgets/zoomable_image_area.dart';

void main() {
  Widget harness({
    Object? resetToken,
    void Function(double velocity, bool vertical)? onSwipe,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(
          child: ZoomableImageArea(
            resetToken: resetToken,
            onSwipe: onSwipe,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
  }

  double currentScale(WidgetTester tester) {
    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    return viewer.transformationController!.value.getMaxScaleOnAxis();
  }

  Future<void> doubleTap(WidgetTester tester) async {
    await tester.tap(find.byType(ZoomableImageArea));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byType(ZoomableImageArea));
    await tester.pumpAndSettle();
  }

  testWidgets('双击在原始比例与放大比例之间切换', (tester) async {
    await tester.pumpWidget(harness());

    expect(currentScale(tester), 1);

    await doubleTap(tester);
    expect(currentScale(tester), greaterThan(1));

    await tester.pump(const Duration(milliseconds: 400));
    await doubleTap(tester);
    expect(currentScale(tester), 1);
  });

  testWidgets('切图后缩放与位移重置', (tester) async {
    await tester.pumpWidget(harness(resetToken: 'a'));
    await doubleTap(tester);
    expect(currentScale(tester), greaterThan(1));

    await tester.pumpWidget(harness(resetToken: 'b'));
    await tester.pump();

    expect(currentScale(tester), 1);
    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(viewer.transformationController!.value, Matrix4.identity());
  });

  testWidgets('原始比例下水平滑动触发切换回调', (tester) async {
    final swipes = <(double, bool)>[];
    await tester.pumpWidget(
      harness(onSwipe: (velocity, vertical) => swipes.add((velocity, vertical))),
    );

    await tester.fling(
      find.byType(ZoomableImageArea),
      const Offset(-300, 0),
      900,
    );
    await tester.pumpAndSettle();

    expect(swipes, isNotEmpty);
    final (velocity, vertical) = swipes.single;
    expect(velocity, lessThan(0));
    expect(vertical, isFalse);
  });

  testWidgets('放大后拖动不触发切换回调', (tester) async {
    final swipes = <(double, bool)>[];
    await tester.pumpWidget(
      harness(onSwipe: (velocity, vertical) => swipes.add((velocity, vertical))),
    );
    await doubleTap(tester);
    expect(currentScale(tester), greaterThan(1));

    await tester.fling(
      find.byType(ZoomableImageArea),
      const Offset(-300, 0),
      900,
    );
    await tester.pumpAndSettle();

    expect(swipes, isEmpty);
  });
}
