import 'package:flutter/material.dart';

import '../../../../shared/state/app_services.dart';
import '../../../../shared/widgets/app_feedback.dart';

/// 「清除已结束任务」二次确认：桌面头部按钮与移动端更多菜单共用，
/// 确认后仅移除成功、失败与已取消任务。
Future<void> confirmAndClearFinishedTasks(
  BuildContext context,
  AppServices controller, {
  required int count,
}) async {
  if (count <= 0) return;
  final confirmed = await AppFeedback.confirm(
    context,
    title: '清除已结束任务？',
    message: '将清除 $count 个已结束任务。清除后这些任务不再出现在列表与本地历史记录中，也无法再重试。',
    confirmLabel: '清除',
    destructive: true,
  );
  if (!confirmed) return;
  controller.transferController.clearCompletedTasks();
  if (context.mounted) {
    AppFeedback.showSnack(context, '已清除 $count 个已结束任务');
  }
}
