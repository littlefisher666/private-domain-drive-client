import 'package:flutter/material.dart';

import '../../../app/theme/cupertino_desktop.dart';
import '../../../shared/state/app_services.dart';
import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../domain/transfer_task.dart';
import 'widgets/transfer_header_actions.dart';
import 'widgets/transfer_selection_actions.dart';
import 'widgets/transfer_type_filter.dart';

part 'transfer_tasks_page_build.dart';

class TransferTasksPage extends StatefulWidget {
  const TransferTasksPage({
    super.key,
    this.embedded = false,
    this.desktopChrome = false,
  });

  final bool embedded;
  final bool desktopChrome;

  @override
  State<TransferTasksPage> createState() => _TransferTasksPageState();
}

class _TransferTasksPageState extends State<TransferTasksPage> {
  TransferTaskType? _selectedType;
  final Set<String> _selectedTaskIds = <String>{};

  bool _canRetry(TransferTask task) =>
      task.status == TransferTaskStatus.failed ||
      task.status == TransferTaskStatus.canceled;

  bool _canCancel(TransferTask task) =>
      task.status == TransferTaskStatus.running ||
      task.status == TransferTaskStatus.pending;

  void _toggleTaskSelection(String taskId, bool selected) {
    setState(() {
      if (selected) {
        _selectedTaskIds.add(taskId);
      } else {
        _selectedTaskIds.remove(taskId);
      }
    });
  }

  void _toggleVisibleTaskSelection(List<TransferTask> tasks) {
    final visibleIds = tasks.map((task) => task.id).toSet();
    setState(() {
      if (visibleIds.isNotEmpty &&
          visibleIds.every(_selectedTaskIds.contains)) {
        _selectedTaskIds.removeAll(visibleIds);
      } else {
        _selectedTaskIds.addAll(visibleIds);
      }
    });
  }

  void _clearTaskSelection() => setState(_selectedTaskIds.clear);

  void _updateSelectedType(TransferTaskType? type) {
    setState(() => _selectedType = type);
  }

  void _retrySelectedTasks(AppServices controller, List<TransferTask> tasks) {
    final taskIds = tasks
        .where((task) => _selectedTaskIds.contains(task.id) && _canRetry(task))
        .map((task) => task.id)
        .toList(growable: false);
    if (taskIds.isEmpty) return;
    controller.transferController.retryTasks(taskIds);
    _clearTaskSelection();
    AppFeedback.showSnack(context, '已重新开始 ${taskIds.length} 个任务');
  }

  void _cancelSelectedTasks(
      AppServices controller, List<TransferTask> tasks) {
    final taskIds = tasks
        .where((task) => _selectedTaskIds.contains(task.id) && _canCancel(task))
        .map((task) => task.id)
        .toList(growable: false);
    if (taskIds.isEmpty) return;
    controller.transferController.cancelTasks(taskIds);
    _clearTaskSelection();
    AppFeedback.showSnack(context, '已取消 ${taskIds.length} 个任务');
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.read(context);
    final theme = Theme.of(context);
    final desktop =
        widget.desktopChrome || MediaQuery.sizeOf(context).width >= 960;

    return ValueListenableBuilder<int>(
      valueListenable: controller.transferQueue.transferConcurrencyListenable,
      builder: (context, _, __) => ValueListenableBuilder<List<TransferTask>>(
        valueListenable: controller.transferQueue.tasksListenable,
        builder: (context, tasks, _) => ValueListenableBuilder<bool>(
          valueListenable: controller.transferQueue.transferQueuePausedListenable,
          builder: (context, paused, _) => _buildBody(
            context: context,
            controller: controller,
            tasks: tasks,
            theme: theme,
            desktop: desktop,
            paused: paused,
          ),
        ),
      ),
    );
  }
}
