import 'package:flutter/widgets.dart';

import '../application/gallery_controller.dart';

class GalleryScope extends InheritedNotifier<GalleryController> {
  const GalleryScope({
    super.key,
    required GalleryController controller,
    required super.child,
  }) : super(notifier: controller);

  static GalleryController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<GalleryScope>();
    assert(scope != null, 'GalleryScope not found in widget tree');
    return scope!.notifier!;
  }
}
