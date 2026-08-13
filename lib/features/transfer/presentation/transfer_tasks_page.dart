import 'package:flutter/material.dart';

import '../../../app/theme/cupertino_desktop.dart';
import '../../../shared/state/app_controller.dart';
import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../domain/transfer_task.dart';

class TransferTasksPage extends StatelessWidget {
  const TransferTasksPage({
    super.key,
    this.embedded = false,
    this.desktopChrome = false,
  });

  final bool embedded;
  final bool desktopChrome;

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
      TransferTaskStatus.running => CupertinoDesktopTokens.blue,
      TransferTaskStatus.success => CupertinoDesktopTokens.success,
      TransferTaskStatus.failed => CupertinoDesktopTokens.danger,
      TransferTaskStatus.canceled => scheme.outline,
    };
  }

  List<Color> _progressColors(TransferTaskStatus status) {
    return switch (status) {
      TransferTaskStatus.failed => const <Color>[Color(0xFFFF9F0A), Color(0xFFFF3B30)],
      TransferTaskStatus.success => const <Color>[Color(0xFF30D158), Color(0xFF34C759)],
      _ => const <Color>[Color(0xFF5AC8FA), Color(0xFF007AFF)],
    };
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.read(context);
    final theme = Theme.of(context);
    final desktop =
        desktopChrome || MediaQuery.sizeOf(context).width >= 960;

    return ValueListenableBuilder<List<TransferTask>>(
      valueListenable: controller.tasksListenable,
      builder: (context, tasks, _) {
        return _buildBody(
          context: context,
          controller: controller,
          tasks: tasks,
          theme: theme,
          desktop: desktop,
        );
      },
    );
  }

  Widget _buildBody({
    required BuildContext context,
    required AppController controller,
    required List<TransferTask> tasks,
    required ThemeData theme,
    required bool desktop,
  }) {

    if (desktop) {
      return ColoredBox(
        color: CupertinoDesktopTokens.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              decoration: const BoxDecoration(
                color: Color(0xE6FFFFFF),
                border: Border(
                  bottom: BorderSide(color: CupertinoDesktopTokens.line),
                ),
              ),
              child: Row(
                children: <Widget>[
                  if (!embedded)
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back),
                    ),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '传输中心',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: CupertinoDesktopTokens.ink,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          '上传 / 下载进度展示，失败可重试，进行中可取消',
                          style: TextStyle(
                            fontSize: 12,
                            color: CupertinoDesktopTokens.secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton(
                    onPressed: tasks.isEmpty
                        ? null
                        : () {
                            controller.clearCompletedTasks();
                            AppFeedback.showSnack(context, '已清除已完成任务');
                          },
                    child: const Text('清除已完成'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: tasks.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无传输任务',
                        style: TextStyle(color: CupertinoDesktopTokens.secondary),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                      itemCount: tasks.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final task = tasks[index];
                        final progressLabel = '${(task.progress * 100).round()}%';
                        final colors = _progressColors(task.status);
                        return Container(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: CupertinoDesktopTokens.line),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      '${task.type == TransferTaskType.upload ? '上传' : '下载'} · ${task.name}',
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: CupertinoDesktopTokens.ink,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    _labelForStatus(task.status),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _colorForStatus(context, task.status),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              if (task.target != null) ...<
                                Widget
                              >[
                                const SizedBox(height: 4),
                                Text(
                                  task.target!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: CupertinoDesktopTokens.secondary,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 10),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(999),
                                child: SizedBox(
                                  height: 8,
                                  child: Stack(
                                    children: <Widget>[
                                      Container(color: const Color(0x29767680)),
                                      FractionallySizedBox(
                                        widthFactor: task.progress.clamp(0.0, 1.0),
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(colors: colors),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: <Widget>[
                                  Text(
                                    progressLabel,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: CupertinoDesktopTokens.secondary,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (task.message != null)
                                    Text(
                                      task.message!,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: CupertinoDesktopTokens.secondary,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: <Widget>[
                                  OutlinedButton(
                                    onPressed: task.status ==
                                                TransferTaskStatus.failed ||
                                            task.status ==
                                                TransferTaskStatus.canceled
                                        ? () {
                                            controller.retryTask(task.id);
                                            AppFeedback.showSnack(
                                              context,
                                              '已重新开始 ${task.name}',
                                            );
                                          }
                                        : null,
                                    child: const Text('重试'),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton(
                                    onPressed: task.status ==
                                                TransferTaskStatus.running ||
                                            task.status ==
                                                TransferTaskStatus.pending
                                        ? () {
                                            controller.cancelTask(task.id);
                                            AppFeedback.showSnack(
                                              context,
                                              '已取消 ${task.name}',
                                            );
                                          }
                                        : null,
                                    child: const Text('取消'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          itemCount: tasks.length + 1,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            if (index == 0) {
              return Row(
                children: <Widget>[
                  if (!embedded)
                    IconButton.filledTonal(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back),
                    ),
                  if (!embedded) const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('传输', style: theme.textTheme.headlineSmall),
                        Text(
                          '上传、下载、重试与取消',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton(
                    onPressed: tasks.isEmpty
                        ? null
                        : () {
                            controller.clearCompletedTasks();
                            AppFeedback.showSnack(context, '已清除已完成任务');
                          },
                    child: const Text('清除已完成'),
                  ),
                ],
              );
            }

            final task = tasks[index - 1];
            final progressLabel = '${(task.progress * 100).round()}%';
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            gradient: LinearGradient(
                              colors: task.type == TransferTaskType.upload
                                  ? const <Color>[Color(0xFF5EEAD4), Color(0xFF0EA5A4)]
                                  : const <Color>[Color(0xFF7DD3FC), Color(0xFF2563EB)],
                            ),
                          ),
                          child: Icon(_iconForType(task.type), color: const Color(0xFF031B1A)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                '${task.type == TransferTaskType.upload ? '上传' : '下载'} · ${task.name}',
                                style: theme.textTheme.titleMedium,
                              ),
                              if (task.target != null)
                                Text(
                                  task.target!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Text(
                          _labelForStatus(task.status),
                          style: TextStyle(
                            color: _colorForStatus(context, task.status),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    LinearProgressIndicator(
                      value: task.progress.clamp(0.0, 1.0),
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    const SizedBox(height: 8),
                    Text('$progressLabel${task.message == null ? '' : ' · ${task.message}'}'),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: <Widget>[
                        OutlinedButton(
                          onPressed: task.status == TransferTaskStatus.failed ||
                                  task.status == TransferTaskStatus.canceled
                              ? () {
                                  controller.retryTask(task.id);
                                  AppFeedback.showSnack(context, '已重新开始 ${task.name}');
                                }
                              : null,
                          child: const Text('重试'),
                        ),
                        OutlinedButton(
                          onPressed: task.status == TransferTaskStatus.running ||
                                  task.status == TransferTaskStatus.pending
                              ? () {
                                  controller.cancelTask(task.id);
                                  AppFeedback.showSnack(context, '已取消 ${task.name}');
                                }
                              : null,
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
      ),
    );
  }
}
