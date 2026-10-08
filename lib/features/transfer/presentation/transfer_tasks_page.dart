import 'package:flutter/material.dart';

import '../../../app/theme/cupertino_desktop.dart';
import '../../../shared/state/app_controller.dart';
import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../domain/transfer_task.dart';

class _TransferHeaderActions extends StatelessWidget {
  const _TransferHeaderActions({required this.controller, required this.tasks});

  final AppController controller;
  final List<TransferTask> tasks;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          '${controller.runningTransferCount}/${controller.transferConcurrency} 进行中 · ${controller.pendingTransferCount} 等待',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        IconButton(
          tooltip: '传输并发数',
          onPressed: () => _showConcurrencyPicker(context, controller),
          icon: const Icon(Icons.tune),
        ),
        OutlinedButton(
          onPressed: tasks.isEmpty
              ? null
              : () {
                  controller.clearCompletedTasks();
                  AppFeedback.showSnack(context, '已清除已完成和已取消任务');
                },
          child: const Text('清除已结束'),
        ),
      ],
    );
  }

  Future<void> _showConcurrencyPicker(
    BuildContext context,
    AppController controller,
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
                  if (value == controller.transferConcurrency)
                    const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (value == null) return;
    await controller.setTransferConcurrency(value);
    if (context.mounted) {
      AppFeedback.showSnack(context, '并发数已设为 $value');
    }
  }
}

class _TransferSelectionActions extends StatelessWidget {
  const _TransferSelectionActions({
    required this.selectedCount,
    required this.allVisibleSelected,
    required this.retryCount,
    required this.cancelCount,
    required this.onToggleAll,
    required this.onRetry,
    required this.onCancel,
    required this.onClear,
  });

  final int selectedCount;
  final bool allVisibleSelected;
  final int retryCount;
  final int cancelCount;
  final VoidCallback onToggleAll;
  final VoidCallback onRetry;
  final VoidCallback onCancel;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          TextButton.icon(
            onPressed: onToggleAll,
            icon: Icon(
              allVisibleSelected
                  ? Icons.check_box_outlined
                  : Icons.select_all_outlined,
            ),
            label: Text(allVisibleSelected ? '取消全选' : '全选当前列表'),
          ),
          if (selectedCount > 0) ...<Widget>[
            Text('已选 $selectedCount 项'),
            OutlinedButton(
              onPressed: retryCount == 0 ? null : onRetry,
              child: Text('批量重试${retryCount == 0 ? '' : ' ($retryCount)'}'),
            ),
            OutlinedButton(
              onPressed: cancelCount == 0 ? null : onCancel,
              child: Text('批量取消${cancelCount == 0 ? '' : ' ($cancelCount)'}'),
            ),
            TextButton(onPressed: onClear, child: const Text('取消选择')),
          ],
        ],
      ),
    );
  }
}

class _TransferTypeFilter extends StatelessWidget {
  const _TransferTypeFilter({
    required this.selectedType,
    required this.tasks,
    required this.onSelected,
    this.dense = false,
  });

  final TransferTaskType? selectedType;
  final List<TransferTask> tasks;
  final ValueChanged<TransferTaskType?> onSelected;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    int count(TransferTaskType type) =>
        tasks.where((task) => task.type == type).length;
    if (!dense) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          border: Border(
            bottom:
                BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          ),
        ),
        child: Wrap(
          spacing: 8,
          children: <Widget>[
            ChoiceChip(
              label: Text('全部 ${tasks.length}'),
              selected: selectedType == null,
              onSelected: (_) => onSelected(null),
            ),
            ChoiceChip(
              label: Text('上传 ${count(TransferTaskType.upload)}'),
              selected: selectedType == TransferTaskType.upload,
              onSelected: (_) => onSelected(TransferTaskType.upload),
            ),
            ChoiceChip(
              label: Text('下载 ${count(TransferTaskType.download)}'),
              selected: selectedType == TransferTaskType.download,
              onSelected: (_) => onSelected(TransferTaskType.download),
            ),
          ],
        ),
      );
    }
    // 移动端用无底色文字 Tab，比 ChoiceChip 明显更矮。
    final theme = Theme.of(context);
    final unselectedStyle = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final selectedStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w700,
    );
    Widget tab(String label, TransferTaskType? type) {
      final selected = selectedType == type;
      return InkWell(
        onTap: () => onSelected(type),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Text(label, style: selected ? selectedStyle : unselectedStyle),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: <Widget>[
          tab('全部 ${tasks.length}', null),
          tab('上传 ${count(TransferTaskType.upload)}', TransferTaskType.upload),
          tab('下载 ${count(TransferTaskType.download)}',
              TransferTaskType.download),
        ],
      ),
    );
  }
}

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

  void _retrySelectedTasks(AppController controller, List<TransferTask> tasks) {
    final taskIds = tasks
        .where((task) => _selectedTaskIds.contains(task.id) && _canRetry(task))
        .map((task) => task.id)
        .toList(growable: false);
    if (taskIds.isEmpty) return;
    controller.retryTasks(taskIds);
    _clearTaskSelection();
    AppFeedback.showSnack(context, '已重新开始 ${taskIds.length} 个任务');
  }

  void _cancelSelectedTasks(
      AppController controller, List<TransferTask> tasks) {
    final taskIds = tasks
        .where((task) => _selectedTaskIds.contains(task.id) && _canCancel(task))
        .map((task) => task.id)
        .toList(growable: false);
    if (taskIds.isEmpty) return;
    controller.cancelTasks(taskIds);
    _clearTaskSelection();
    AppFeedback.showSnack(context, '已取消 ${taskIds.length} 个任务');
  }

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
      TransferTaskStatus.failed => const <Color>[
          Color(0xFFFF9F0A),
          Color(0xFFFF3B30)
        ],
      TransferTaskStatus.success => const <Color>[
          Color(0xFF30D158),
          Color(0xFF34C759)
        ],
      _ => const <Color>[Color(0xFF5AC8FA), Color(0xFF007AFF)],
    };
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String? _transferDetails(TransferTask task) {
    if (task.status != TransferTaskStatus.running) return null;
    final total = task.totalBytes;
    final amount = total == null
        ? _formatBytes(task.transferredBytes)
        : '${_formatBytes(task.transferredBytes)} / ${_formatBytes(total)}';
    final speed = task.bytesPerSecond;
    return speed == null || speed <= 0
        ? amount
        : '$amount · ${_formatBytes(speed.round())}/s';
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.read(context);
    final theme = Theme.of(context);
    final desktop =
        widget.desktopChrome || MediaQuery.sizeOf(context).width >= 960;

    return ValueListenableBuilder<int>(
      valueListenable: controller.transferConcurrencyListenable,
      builder: (context, _, __) => ValueListenableBuilder<List<TransferTask>>(
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
      ),
    );
  }

  Widget _buildBody({
    required BuildContext context,
    required AppController controller,
    required List<TransferTask> tasks,
    required ThemeData theme,
    required bool desktop,
  }) {
    // 展示顺序：进行中 > 等待中 > 已结束；同状态内新任务在前
    // （任务列表按入队顺序追加，索引越大越新）。
    int statusRank(TransferTaskStatus status) => switch (status) {
          TransferTaskStatus.running => 0,
          TransferTaskStatus.pending => 1,
          _ => 2,
        };
    final candidates = (_selectedType == null
            ? tasks
            : tasks.where((task) => task.type == _selectedType).toList())
        .asMap()
        .entries
        .map((entry) => (index: entry.key, task: entry.value))
        .toList();
    candidates.sort((a, b) {
      final rank = statusRank(a.task.status) - statusRank(b.task.status);
      return rank != 0 ? rank : b.index - a.index;
    });
    final visibleTasks =
        candidates.map((entry) => entry.task).toList(growable: false);
    final typeFilter = _TransferTypeFilter(
      selectedType: _selectedType,
      tasks: tasks,
      onSelected: (type) => setState(() => _selectedType = type),
      dense: !desktop,
    );
    final selectedTasks = tasks
        .where((task) => _selectedTaskIds.contains(task.id))
        .toList(growable: false);
    final retryCount = selectedTasks.where(_canRetry).length;
    final cancelCount = selectedTasks.where(_canCancel).length;
    final allVisibleSelected = visibleTasks.isNotEmpty &&
        visibleTasks.every((task) => _selectedTaskIds.contains(task.id));
    final batchActions = _TransferSelectionActions(
      selectedCount: selectedTasks.length,
      allVisibleSelected: allVisibleSelected,
      retryCount: retryCount,
      cancelCount: cancelCount,
      onToggleAll: () => _toggleVisibleTaskSelection(visibleTasks),
      onRetry: () => _retrySelectedTasks(controller, tasks),
      onCancel: () => _cancelSelectedTasks(controller, tasks),
      onClear: _clearTaskSelection,
    );
    if (desktop) {
      return ColoredBox(
        color: theme.colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.9),
                border: Border(
                  bottom: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: Row(
                children: <Widget>[
                  if (!widget.embedded)
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '传输中心',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '上传 / 下载进度展示，失败可重试，进行中可取消',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _TransferHeaderActions(controller: controller, tasks: tasks),
                ],
              ),
            ),
            typeFilter,
            batchActions,
            Expanded(
              child: visibleTasks.isEmpty
                  ? Center(
                      child: Text(
                        _selectedType == TransferTaskType.upload
                            ? '暂无上传任务'
                            : _selectedType == TransferTaskType.download
                                ? '暂无下载任务'
                                : '暂无传输任务',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                      itemCount: visibleTasks.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final task = visibleTasks[index];
                        final progressLabel =
                            '${(task.progress * 100).round()}%';
                        final transferDetails = _transferDetails(task);
                        final colors = _progressColors(task.status);
                        final completed =
                            task.status == TransferTaskStatus.success;
                        return Container(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Checkbox(
                                    value: _selectedTaskIds.contains(task.id),
                                    onChanged: (selected) =>
                                        _toggleTaskSelection(
                                      task.id,
                                      selected ?? false,
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      '${task.type == TransferTaskType.upload ? '上传' : '下载'} · ${task.name}',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: theme.colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    _labelForStatus(task.status),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color:
                                          _colorForStatus(context, task.status),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              if (task.target != null) ...<Widget>[
                                const SizedBox(height: 4),
                                Text(
                                  task.target!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 10),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(999),
                                child: SizedBox(
                                  height: 8,
                                  child: LinearProgressIndicator(
                                    value: task.progress.clamp(0.0, 1.0),
                                    minHeight: 8,
                                    color: completed
                                        ? const Color(0xFF34C759)
                                        : colors.last,
                                    backgroundColor: completed
                                        ? const Color(0x2634C759)
                                        : const Color(0x29767680),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: <Widget>[
                                  Text(
                                    progressLabel,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (transferDetails != null)
                                    Text(
                                      transferDetails,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  if (transferDetails != null &&
                                      task.message != null)
                                    const SizedBox(width: 8),
                                  if (task.message != null)
                                    Text(
                                      task.message!,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
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

    final unfinishedTasks = tasks
        .where((task) =>
            task.status == TransferTaskStatus.running ||
            task.status == TransferTaskStatus.pending)
        .toList(growable: false);
    final unfinishedTotalBytes = unfinishedTasks.fold<int>(
        0, (sum, task) => sum + (task.totalBytes ?? 0));
    final unfinishedTransferredBytes = unfinishedTasks.fold<int>(
        0, (sum, task) => sum + task.transferredBytes);
    final globalSpeed = unfinishedTasks
        .where((task) => task.status == TransferTaskStatus.running)
        .fold<double>(0, (sum, task) => sum + (task.bytesPerSecond ?? 0));
    final statsStyle = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    // 任务总数由下方筛选 Tab 展示，这里不再重复，避免长文本截断进度。
    final statsText = tasks.isEmpty
        ? '上传、下载、重试与取消'
        : <String>[
            '${controller.runningTransferCount} 进行中 · '
                '${controller.pendingTransferCount} 等待',
            if (unfinishedTotalBytes > 0)
              '${_formatBytes(unfinishedTransferredBytes)} / ${_formatBytes(unfinishedTotalBytes)}',
            if (globalSpeed > 0) '${_formatBytes(globalSpeed.round())}/s',
          ].join(' · ');

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      if (!widget.embedded)
                        IconButton.filledTonal(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back),
                        ),
                      if (!widget.embedded) const SizedBox(width: 12),
                      Expanded(
                        child: Text('传输', style: theme.textTheme.headlineSmall),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '传输设置',
                        onSelected: (value) {
                          controller.clearCompletedTasks();
                          AppFeedback.showSnack(context, '已清除已结束任务');
                        },
                        itemBuilder: (_) => const <PopupMenuEntry<String>>[
                          PopupMenuItem(
                            value: 'clear',
                            child: Text('清除已结束任务'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Text(
                    statsText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: statsStyle,
                  ),
                ],
              ),
            ),
            typeFilter,
            Expanded(
              child: visibleTasks.isEmpty
                  ? Center(
                      child: Text(
                        _selectedType == TransferTaskType.upload
                            ? '暂无上传任务'
                            : _selectedType == TransferTaskType.download
                                ? '暂无下载任务'
                                : '暂无传输任务',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                      itemCount: visibleTasks.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, index) => _buildMobileTaskCard(
                        context: context,
                        controller: controller,
                        theme: theme,
                        task: visibleTasks[index],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileTaskCard({
    required BuildContext context,
    required AppController controller,
    required ThemeData theme,
    required TransferTask task,
  }) {
    final progressLabel = '${(task.progress * 100).round()}%';
    final canRetry = task.status == TransferTaskStatus.failed ||
        task.status == TransferTaskStatus.canceled;
    final canCancel = task.status == TransferTaskStatus.running ||
        task.status == TransferTaskStatus.pending;
    final transferDetails = _transferDetails(task);
    // 状态徽章已展示「进行中/已完成」等文案，这里跳过重复的 message，
    // 避免「60% · 100.5 MB / 166.2 MB · 2.0 MB/s · 进行中」超宽被省略号截断。
    final statusLabel = _labelForStatus(task.status);
    final message = (task.message == null || task.message == statusLabel)
        ? null
        : task.message;
    final progressText = <String>[
      if (transferDetails != null) transferDetails,
      if (message != null) message,
    ].join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    gradient: LinearGradient(
                      colors: task.type == TransferTaskType.upload
                          ? const <Color>[Color(0xFF5EEAD4), Color(0xFF0EA5A4)]
                          : const <Color>[Color(0xFF7DD3FC), Color(0xFF2563EB)],
                    ),
                  ),
                  child: Icon(_iconForType(task.type),
                      size: 16, color: const Color(0xFF031B1A)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    task.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _colorForStatus(context, task.status)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _labelForStatus(task.status),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: _colorForStatus(context, task.status),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (task.target != null) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                task.target!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: LinearProgressIndicator(
                    value: task.progress.clamp(0.0, 1.0),
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(999),
                    color: task.status == TransferTaskStatus.success
                        ? CupertinoDesktopTokens.success
                        : null,
                    backgroundColor: task.status == TransferTaskStatus.success
                        ? CupertinoDesktopTokens.success.withValues(alpha: 0.16)
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 38,
                  child: Text(
                    progressLabel,
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (progressText.isNotEmpty || canRetry || canCancel) ...<Widget>[
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      progressText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (canRetry)
                    IconButton(
                      tooltip: '重试',
                      visualDensity: VisualDensity.compact,
                      constraints:
                          const BoxConstraints.tightFor(width: 32, height: 32),
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        controller.retryTask(task.id);
                        AppFeedback.showSnack(context, '已重新开始 ${task.name}');
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                    ),
                  if (canCancel)
                    IconButton(
                      tooltip: '取消传输',
                      visualDensity: VisualDensity.compact,
                      constraints:
                          const BoxConstraints.tightFor(width: 32, height: 32),
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        controller.cancelTask(task.id);
                        AppFeedback.showSnack(context, '已取消 ${task.name}');
                      },
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
