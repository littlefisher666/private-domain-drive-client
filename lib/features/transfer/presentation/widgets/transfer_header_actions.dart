import 'package:flutter/material.dart';

import '../../../../shared/state/app_services.dart';
import '../../../../shared/widgets/app_feedback.dart';
import '../../domain/transfer_task.dart';

class TransferHeaderActions extends StatelessWidget {
  const TransferHeaderActions({
    super.key,
    required this.controller,
    required this.tasks,
    required this.paused,
  });

  final AppServices controller;
  final List<TransferTask> tasks;
  final bool paused;

  @override
  Widget build(BuildContext context) {
    final interruptedCount = tasks
        .where((task) =>
            task.type == TransferTaskType.upload &&
            task.status == TransferTaskStatus.interrupted)
        .length;
    final hasActiveTasks = tasks.any((task) =>
        task.status == TransferTaskStatus.running ||
        task.status == TransferTaskStatus.pending);
    return Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          '${controller.transferQueue.runningTransferCount}/${controller.transferQueue.transferConcurrency} 进行中 · ${controller.transferQueue.pendingTransferCount} 等待'
          '${paused ? ' · 已暂停' : ''}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        IconButton(
          tooltip: '传输并发数',
          onPressed: () => _showConcurrencyPicker(context, controller),
          icon: const Icon(Icons.tune),
        ),
        if (hasActiveTasks) ...<Widget>[
          OutlinedButton.icon(
            onPressed: () {
              if (paused) {
                controller.transferController.resumeAllTransfers();
                AppFeedback.showSnack(context, '已继续全部传输任务');
              } else {
                controller.transferController.pauseAllTransfers();
                AppFeedback.showSnack(context, '已暂停全部传输任务');
              }
            },
            icon: Icon(
              paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              size: 18,
            ),
            label: Text(paused ? '继续全部' : '暂停全部'),
          ),
          OutlinedButton(
            onPressed: () {
              controller.transferController.cancelAllTransfers();
              AppFeedback.showSnack(context, '已取消全部未完成任务');
            },
            child: const Text('全部取消'),
          ),
        ],
        if (interruptedCount > 0) ...<Widget>[
          OutlinedButton(
            onPressed: () {
              controller.transferController.resumeAllInterruptedUploads();
              AppFeedback.showSnack(context, '已继续上传 $interruptedCount 个中断任务');
            },
            child: Text('全部继续 ($interruptedCount)'),
          ),
          OutlinedButton(
            onPressed: () {
              controller.transferController.abandonAllInterruptedUploads();
              AppFeedback.showSnack(context, '已放弃 $interruptedCount 个中断任务');
            },
            child: const Text('全部放弃'),
          ),
        ],
        OutlinedButton(
          onPressed: tasks.isEmpty
              ? null
              : () {
                  controller.transferController.clearCompletedTasks();
                  AppFeedback.showSnack(context, '已清除已完成和已取消任务');
                },
          child: const Text('清除已结束'),
        ),
      ],
    );
  }

  Future<void> _showConcurrencyPicker(
    BuildContext context,
    AppServices controller,
  ) async {
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('总传输并发数'),
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text('上传和下载共用此上限，默认值为 3。'),
          ),
          const SizedBox(height: 8),
          for (var value = 1; value <= 5; value++)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(value),
              child: Row(
                children: <Widget>[
                  Expanded(child: Text('$value 个并发')),
                  if (value == controller.transferQueue.transferConcurrency)
                    const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (value == null) return;
    await controller.transferQueue.setTransferConcurrency(value);
    if (context.mounted) {
      AppFeedback.showSnack(context, '并发数已设为 $value');
    }
  }
}
