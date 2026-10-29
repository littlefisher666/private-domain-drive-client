import 'package:flutter/material.dart';

import '../../../../shared/state/app_services.dart';
import '../../../../shared/widgets/app_feedback.dart';
import '../../domain/transfer_task.dart';
import 'transfer_clear_finished.dart';
import 'transfer_concurrency_picker.dart';

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
    final finishedCount = tasks.where((task) => task.isFinished).length;
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
          onPressed: () => showTransferConcurrencyPicker(context, controller),
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
          onPressed: finishedCount == 0
              ? null
              : () => confirmAndClearFinishedTasks(
                    context,
                    controller,
                    count: finishedCount,
                  ),
          child: const Text('清除已结束'),
        ),
      ],
    );
  }
}
