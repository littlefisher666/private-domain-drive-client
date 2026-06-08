import 'package:flutter/material.dart';

import '../domain/transfer_task.dart';

class TransferTasksPage extends StatelessWidget {
  const TransferTasksPage({super.key});

  static const _tasks = <TransferTask>[
    TransferTask(
      id: 'task-1',
      name: '2026-trip.jpg',
      type: TransferTaskType.upload,
      status: TransferTaskStatus.running,
      progress: 0.64,
      message: '上传到 shared/photos/',
    ),
    TransferTask(
      id: 'task-2',
      name: 'family-rules.pdf',
      type: TransferTaskType.download,
      status: TransferTaskStatus.success,
      progress: 1,
      message: '已保存到下载目录',
    ),
    TransferTask(
      id: 'task-3',
      name: 'project-plan.md',
      type: TransferTaskType.upload,
      status: TransferTaskStatus.failed,
      progress: 0.35,
      message: '网络中断，可重试',
    ),
    TransferTask(
      id: 'task-4',
      name: 'server-config.json',
      type: TransferTaskType.download,
      status: TransferTaskStatus.pending,
      progress: 0,
      message: '等待开始',
    ),
  ];

  IconData _iconForType(TransferTaskType type) {
    return switch (type) {
      TransferTaskType.upload => Icons.upload_file_outlined,
      TransferTaskType.download => Icons.download_outlined,
    };
  }

  String _labelForStatus(TransferTaskStatus status) {
    return switch (status) {
      TransferTaskStatus.pending => '等待中',
      TransferTaskStatus.running => '进行中',
      TransferTaskStatus.success => '已完成',
      TransferTaskStatus.failed => '失败',
      TransferTaskStatus.canceled => '已取消',
    };
  }

  Color _colorForStatus(BuildContext context, TransferTaskStatus status) {
    final scheme = Theme.of(context).colorScheme;
    return switch (status) {
      TransferTaskStatus.pending => scheme.secondary,
      TransferTaskStatus.running => scheme.primary,
      TransferTaskStatus.success => Colors.green,
      TransferTaskStatus.failed => scheme.error,
      TransferTaskStatus.canceled => scheme.outline,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('传输任务'),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _tasks.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final task = _tasks[index];
          final progressLabel = '${(task.progress * 100).round()}%';
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(_iconForType(task.type)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          task.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      Text(
                        _labelForStatus(task.status),
                        style: TextStyle(
                          color: _colorForStatus(context, task.status),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: task.progress),
                  const SizedBox(height: 8),
                  Text(progressLabel),
                  if (task.message != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(task.message!),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: <Widget>[
                      OutlinedButton(
                        onPressed: task.status == TransferTaskStatus.failed ? () {} : null,
                        child: const Text('重试'),
                      ),
                      OutlinedButton(
                        onPressed: task.status == TransferTaskStatus.running ? () {} : null,
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
