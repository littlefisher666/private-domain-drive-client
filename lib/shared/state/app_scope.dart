import 'package:flutter/widgets.dart';

import 'app_services.dart';

/// 应用级控制器作用域：经 [InheritedNotifier] 向下提供 [AppServices] 聚合层。
///
/// 子控制器通知由 [AppServices] 统一转发，依赖 [AppScope] 的界面在任一
/// 控制器发出通知时重建，行为与原门面时期一致。
class AppScope extends InheritedNotifier<AppServices> {
  const AppScope({
    super.key,
    required AppServices services,
    required super.child,
  }) : super(notifier: services);

  static AppServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found in widget tree');
    return scope!.notifier!;
  }

  static AppServices read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found in widget tree');
    return scope!.notifier!;
  }
}
