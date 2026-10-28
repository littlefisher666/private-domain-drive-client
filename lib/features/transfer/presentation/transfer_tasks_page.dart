import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/theme/cupertino_desktop.dart';
import '../../../shared/state/app_services.dart';
import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../domain/transfer_task.dart';
import '../domain/transfer_type_counts.dart';
import 'transfer_format.dart';
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

  /// 排队中/进行中任务的“已等待/已用”时长每秒刷新一次；仅当列表中
  /// 存在未结束任务时启用，页面销毁或任务全部结束时取消。
  final ValueNotifier<DateTime> _clock = ValueNotifier(DateTime.now());
  Timer? _clockTimer;
  bool _clockActive = false;

  void _syncLiveClock(List<TransferTask> tasks) {
    final active = tasks.any((task) =>
        task.status == TransferTaskStatus.pending ||
        task.status == TransferTaskStatus.running);
    if (active == _clockActive) return;
    _clockActive = active;
    if (active) {
      _clockTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (_clockActive) _clock.value = DateTime.now();
      });
      // 在 build 中启动计时器时不能同步更新 notifier，推迟到帧结束后。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _clockActive) _clock.value = DateTime.now();
      });
    } else {
      _clockTimer?.cancel();
      _clockTimer = null;
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _clock.dispose();
    super.dispose();
  }

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
        builder: (context, tasks, _) {
          _syncLiveClock(tasks);
          return ValueListenableBuilder<bool>(
            valueListenable:
                controller.transferQueue.transferQueuePausedListenable,
            builder: (context, paused, _) =>
                ValueListenableBuilder<TransferTypeCounts?>(
              valueListenable: controller.transferQueue.historyCountsListenable,
              builder: (context, _, __) => _buildBody(
                context: context,
                controller: controller,
                tasks: tasks,
                counts: controller.transferQueue.typeCounts,
                theme: theme,
                desktop: desktop,
                paused: paused,
              ),
            ),
          );
        },
      ),
    );
  }
}
