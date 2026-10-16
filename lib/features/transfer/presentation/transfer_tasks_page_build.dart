part of 'transfer_tasks_page.dart';

/// `_TransferTasksPageState` 的 build 辅助方法：桌面/移动端整体布局、
/// 任务卡片与传输详情、状态映射与格式化工具。
///
/// Dart 的 part 文件只能承载顶层声明，因此这里以同库私有 extension 的
/// 形态挂回 State 类；调用方式与实例方法完全一致，无行为差异。
extension _TransferTasksPageBuild on _TransferTasksPageState {
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
      TransferTaskStatus.interrupted => '已中断',
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
      TransferTaskStatus.interrupted => CupertinoDesktopTokens.warning,
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

  Widget _buildBody({
    required BuildContext context,
    required AppServices controller,
    required List<TransferTask> tasks,
    required ThemeData theme,
    required bool desktop,
    required bool paused,
  }) {
    // 展示顺序：进行中 > 等待中 > 已中断 > 已结束；同状态内新任务在前
    // （任务列表按入队顺序追加，索引越大越新）。
    int statusRank(TransferTaskStatus status) => switch (status) {
          TransferTaskStatus.running => 0,
          TransferTaskStatus.pending => 1,
          TransferTaskStatus.interrupted => 2,
          _ => 3,
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
    final typeFilter = TransferTypeFilter(
      selectedType: _selectedType,
      tasks: tasks,
      onSelected: _updateSelectedType,
      dense: !desktop,
    );
    final selectedTasks = tasks
        .where((task) => _selectedTaskIds.contains(task.id))
        .toList(growable: false);
    final retryCount = selectedTasks.where(_canRetry).length;
    final cancelCount = selectedTasks.where(_canCancel).length;
    final allVisibleSelected = visibleTasks.isNotEmpty &&
        visibleTasks.every((task) => _selectedTaskIds.contains(task.id));
    final batchActions = TransferSelectionActions(
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
                  TransferHeaderActions(
                    controller: controller,
                    tasks: tasks,
                    paused: paused,
                  ),
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
                                  if (task.status ==
                                      TransferTaskStatus.interrupted) ...<Widget>[
                                    OutlinedButton(
                                      onPressed: () {
                                        controller.transferController
                                            .resumeInterruptedUpload(task.id);
                                        AppFeedback.showSnack(
                                          context,
                                          '已继续上传 ${task.name}',
                                        );
                                      },
                                      child: const Text('继续上传'),
                                    ),
                                    const SizedBox(width: 8),
                                    OutlinedButton(
                                      onPressed: () {
                                        controller.transferController
                                            .abandonInterruptedUpload(task.id);
                                        AppFeedback.showSnack(
                                          context,
                                          '已放弃 ${task.name}',
                                        );
                                      },
                                      child: const Text('放弃'),
                                    ),
                                  ] else ...<Widget>[
                                    OutlinedButton(
                                      onPressed: task.status ==
                                                  TransferTaskStatus.failed ||
                                              task.status ==
                                                  TransferTaskStatus.canceled
                                          ? () {
                                              controller.transferController.retryTask(task.id);
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
                                              controller.transferController.cancelTask(task.id);
                                              AppFeedback.showSnack(
                                                context,
                                                '已取消 ${task.name}',
                                              );
                                            }
                                          : null,
                                      child: const Text('取消'),
                                    ),
                                  ],
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
    final interruptedCount = tasks
        .where((task) =>
            task.type == TransferTaskType.upload &&
            task.status == TransferTaskStatus.interrupted)
        .length;
    final activeCount = tasks
        .where((task) =>
            task.status == TransferTaskStatus.running ||
            task.status == TransferTaskStatus.pending)
        .length;
    // 任务总数由下方筛选 Tab 展示，这里不再重复，避免长文本截断进度。
    final statsText = tasks.isEmpty
        ? '上传、下载、重试与取消'
        : <String>[
            '${controller.transferQueue.runningTransferCount} 进行中 · '
                '${controller.transferQueue.pendingTransferCount} 等待',
            if (paused) '已暂停',
            if (interruptedCount > 0) '$interruptedCount 个已中断',
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
                          if (value == 'pause-all') {
                            controller.transferController.pauseAllTransfers();
                            AppFeedback.showSnack(context, '已暂停全部传输任务');
                          } else if (value == 'resume-queue') {
                            controller.transferController.resumeAllTransfers();
                            AppFeedback.showSnack(context, '已继续全部传输任务');
                          } else if (value == 'cancel-all') {
                            controller.transferController.cancelAllTransfers();
                            AppFeedback.showSnack(context, '已取消全部未完成任务');
                          } else if (value == 'resume-all') {
                            controller.transferController.resumeAllInterruptedUploads();
                            AppFeedback.showSnack(
                                context, '已继续上传 $interruptedCount 个中断任务');
                          } else if (value == 'abandon-all') {
                            controller.transferController.abandonAllInterruptedUploads();
                            AppFeedback.showSnack(
                                context, '已放弃 $interruptedCount 个中断任务');
                          } else if (value == 'clear') {
                            controller.transferController.clearCompletedTasks();
                            AppFeedback.showSnack(context, '已清除已结束任务');
                          }
                        },
                        itemBuilder: (_) => <PopupMenuEntry<String>>[
                          if (activeCount > 0) ...<PopupMenuEntry<String>>[
                            PopupMenuItem(
                              value: paused ? 'resume-queue' : 'pause-all',
                              child: Text(paused ? '继续全部任务' : '暂停全部任务'),
                            ),
                            const PopupMenuItem(
                              value: 'cancel-all',
                              child: Text('全部取消'),
                            ),
                          ],
                          if (interruptedCount > 0) ...<PopupMenuEntry<String>>[
                            PopupMenuItem(
                              value: 'resume-all',
                              child: Text('全部继续 ($interruptedCount)'),
                            ),
                            const PopupMenuItem(
                              value: 'abandon-all',
                              child: Text('全部放弃'),
                            ),
                          ],
                          const PopupMenuItem(
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
    required AppServices controller,
    required ThemeData theme,
    required TransferTask task,
  }) {
    final progressLabel = '${(task.progress * 100).round()}%';
    final isInterrupted = task.status == TransferTaskStatus.interrupted;
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
            if (progressText.isNotEmpty ||
                isInterrupted ||
                canRetry ||
                canCancel) ...<Widget>[
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
                  if (isInterrupted) ...<Widget>[
                    IconButton(
                      tooltip: '继续上传',
                      visualDensity: VisualDensity.compact,
                      constraints:
                          const BoxConstraints.tightFor(width: 32, height: 32),
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        controller.transferController.resumeInterruptedUpload(task.id);
                        AppFeedback.showSnack(context, '已继续上传 ${task.name}');
                      },
                      icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    ),
                    IconButton(
                      tooltip: '放弃任务',
                      visualDensity: VisualDensity.compact,
                      constraints:
                          const BoxConstraints.tightFor(width: 32, height: 32),
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        controller.transferController.abandonInterruptedUpload(task.id);
                        AppFeedback.showSnack(context, '已放弃 ${task.name}');
                      },
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    ),
                  ],
                  if (canRetry)
                    IconButton(
                      tooltip: '重试',
                      visualDensity: VisualDensity.compact,
                      constraints:
                          const BoxConstraints.tightFor(width: 32, height: 32),
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        controller.transferController.retryTask(task.id);
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
                        controller.transferController.cancelTask(task.id);
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
