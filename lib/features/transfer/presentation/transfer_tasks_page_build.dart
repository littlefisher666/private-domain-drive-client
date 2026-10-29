part of 'transfer_tasks_page.dart';

/// `_TransferTasksPageState` 的 build 辅助方法：桌面/移动端整体布局、
/// 任务卡片、任务详情、状态映射、时间线格式化与历史分页交互。
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

  bool _isLiveStatus(TransferTask task) =>
      task.status == TransferTaskStatus.pending ||
      task.status == TransferTaskStatus.running;

  String? _runningDetails(TransferTask task) {
    if (task.status != TransferTaskStatus.running) return null;
    final total = task.totalBytes;
    final amount = total == null
        ? formatTransferBytes(task.transferredBytes)
        : '${formatTransferBytes(task.transferredBytes)} / '
            '${formatTransferBytes(total)}';
    final speed = task.bytesPerSecond;
    return speed == null || speed <= 0
        ? amount
        : '$amount · ${formatTransferSpeed(speed)}';
  }

  String _finishedSize(TransferTask task) {
    final size = task.status == TransferTaskStatus.success
        ? task.totalBytes ?? task.transferredBytes
        : task.transferredBytes;
    return formatTransferBytes(size);
  }

  /// 已结束卡片摘要："大小 · 耗时 · 均速"。
  String _finishedSummary(TransferTask task) {
    final duration = task.activeDurationMs > 0
        ? formatTransferDuration(task.activeDurationMs)
        : transferUnknownPlaceholder;
    final speed = task.averageBytesPerSecond;
    final speedText =
        speed == null ? transferUnknownPlaceholder : formatTransferSpeed(speed);
    return '${_finishedSize(task)} · 耗时 $duration · 均速 $speedText';
  }

  String _finishedTime(TransferTask task) {
    return '结束于 ${formatTransferTimestamp(task.finishedAt)}';
  }

  String? _liveDuration(TransferTask task, DateTime now) {
    if (task.status == TransferTaskStatus.pending) {
      final queued = task.queuedTime;
      if (queued == null) return '已等待 $transferUnknownPlaceholder';
      return '已等待 ${formatTransferDuration(now.difference(queued).inMilliseconds)}';
    }
    if (task.status == TransferTaskStatus.running) {
      final started = task.lastStartedAt ?? task.startedAt;
      if (started == null) return '已用 $transferUnknownPlaceholder';
      return '已用 ${formatTransferDuration(now.difference(started).inMilliseconds)}';
    }
    return null;
  }

  /// 卡片底部信息行：已结束展示摘要，进行中展示字节/速度与已用时长，
  /// 排队中展示已等待时长。与状态徽章重复的 message 不重复拼接。
  String _cardInfoLine(
    TransferTask task,
    DateTime now, {
    required bool hideDuplicateMessage,
  }) {
    if (task.isFinished) {
      final message = hideDuplicateMessage &&
              (task.message == null ||
                  task.message == _labelForStatus(task.status))
          ? null
          : task.message;
      return <String>[
        _finishedSummary(task),
        if (message != null) message,
      ].join(' · ');
    }
    final statusLabel = _labelForStatus(task.status);
    final message = (task.message == null || task.message == statusLabel)
        ? null
        : task.message;
    final parts = <String>[];
    final runningDetails = _runningDetails(task);
    if (runningDetails != null) parts.add(runningDetails);
    final liveDuration = _liveDuration(task, now);
    if (liveDuration != null) parts.add(liveDuration);
    if (message != null) parts.add(message);
    return parts.join(' · ');
  }

  Widget _buildHistoryFooter(AppServices controller, ThemeData theme) {
    return ValueListenableBuilder<bool>(
      valueListenable: controller.transferQueue.historyLoadingListenable,
      builder: (context, loading, _) {
        if (loading) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Center(
            child: TextButton(
              onPressed: controller.transferQueue.loadMoreHistory,
              child: const Text('加载更多历史'),
            ),
          ),
        );
      },
    );
  }

  bool _handleScrollNotification(
    ScrollNotification notification,
    AppServices controller,
  ) {
    if (notification.depth != 0) return false;
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      if (notification.metrics.extentAfter < 200) {
        unawaited(controller.transferQueue.loadMoreHistory());
      }
    }
    return false;
  }

  void _scheduleAutoLoadWhenEmpty(
    AppServices controller,
    List<TransferTask> visibleTasks,
  ) {
    final queue = controller.transferQueue;
    if (visibleTasks.isNotEmpty || !queue.historyHasMore || queue.historyLoading) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      queue.loadMoreHistory();
    });
  }

  /// 空态：完全无任务时展示说明与「去文件页」入口；类型筛选无结果时
  /// 只展示该类型的空态文案，不展示跨类型引导。
  Widget _buildEmptyState({
    required ThemeData theme,
    required bool typeFiltered,
  }) {
    final mutedStyle = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    if (typeFiltered) {
      return Center(
        child: Text(
          _selectedType == TransferTaskType.upload ? '暂无上传任务' : '暂无下载任务',
          style: mutedStyle,
        ),
      );
    }
    final onOpenFiles = widget.onOpenFiles;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.swap_vert_circle_outlined,
            size: 44,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 12),
          Text('暂无传输任务', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('上传或下载后任务会出现在这里', style: mutedStyle),
          if (onOpenFiles != null) ...<Widget>[
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: onOpenFiles,
              child: const Text('去文件页'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody({
    required BuildContext context,
    required AppServices controller,
    required List<TransferTask> tasks,
    required TransferTypeCounts counts,
    required ThemeData theme,
    required bool desktop,
    required bool paused,
  }) {
    // 展示顺序：进行中 > 等待中 > 已中断 > 已结束。同状态内：未结束按
    // 首次入队时间倒序，已结束按结束时间倒序；缺失时间时 id 兜底，
    // 保证重启恢复后的顺序稳定。
    int statusRank(TransferTaskStatus status) => switch (status) {
          TransferTaskStatus.running => 0,
          TransferTaskStatus.pending => 1,
          TransferTaskStatus.interrupted => 2,
          _ => 3,
        };
    int compareByTime(DateTime? a, DateTime? b) {
      if (a != null && b != null) return b.compareTo(a);
      if (a == null && b != null) return 1;
      if (a != null && b == null) return -1;
      return 0;
    }

    final candidates = (_selectedType == null
            ? tasks
            : tasks.where((task) => task.type == _selectedType).toList())
        .map((task) => (task: task))
        .toList();
    candidates.sort((a, b) {
      final rank = statusRank(a.task.status) - statusRank(b.task.status);
      if (rank != 0) return rank;
      final byTime = a.task.isFinished
          ? compareByTime(a.task.finishedAt, b.task.finishedAt)
          : compareByTime(a.task.queuedTime, b.task.queuedTime);
      if (byTime != 0) return byTime;
      return b.task.id.compareTo(a.task.id);
    });
    final visibleTasks =
        candidates.map((entry) => entry.task).toList(growable: false);
    final queue = controller.transferQueue;
    final hasMore = queue.historyHasMore;
    final finishedCount = tasks.where((task) => task.isFinished).length;
    _scheduleAutoLoadWhenEmpty(controller, visibleTasks);

    final typeFilter = TransferTypeFilter(
      selectedType: _selectedType,
      counts: counts,
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
    final emptyState = _buildEmptyState(
      theme: theme,
      typeFiltered: _selectedType != null,
    );

    if (desktop) {
      final itemCount = visibleTasks.length + (hasMore ? 1 : 0);
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
              child: visibleTasks.isEmpty && !hasMore
                  ? emptyState
                  : NotificationListener<ScrollNotification>(
                      onNotification: (notification) =>
                          _handleScrollNotification(notification, controller),
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        itemCount: itemCount,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          if (index >= visibleTasks.length) {
                            return _buildHistoryFooter(controller, theme);
                          }
                          return _buildDesktopTaskCard(
                            context: context,
                            controller: controller,
                            theme: theme,
                            task: visibleTasks[index],
                          );
                        },
                      ),
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
              '${formatTransferBytes(unfinishedTransferredBytes)} / '
                  '${formatTransferBytes(unfinishedTotalBytes)}',
            if (globalSpeed > 0) formatTransferSpeed(globalSpeed),
          ].join(' · ');

    final itemCount = visibleTasks.length + (hasMore ? 1 : 0);
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
                          } else if (value == 'concurrency') {
                            unawaited(showTransferConcurrencyPicker(
                                context, controller));
                          } else if (value == 'clear') {
                            unawaited(confirmAndClearFinishedTasks(
                              context,
                              controller,
                              count: finishedCount,
                            ));
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
                            value: 'concurrency',
                            child: Text('传输并发数'),
                          ),
                          PopupMenuItem(
                            value: 'clear',
                            enabled: finishedCount > 0,
                            child: Text(finishedCount > 0
                                ? '清除已结束任务 ($finishedCount)'
                                : '清除已结束任务'),
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
              child: visibleTasks.isEmpty && !hasMore
                  ? emptyState
                  : NotificationListener<ScrollNotification>(
                      onNotification: (notification) =>
                          _handleScrollNotification(notification, controller),
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                        itemCount: itemCount,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (context, index) {
                          if (index >= visibleTasks.length) {
                            return _buildHistoryFooter(controller, theme);
                          }
                          return _buildMobileTaskCard(
                            context: context,
                            controller: controller,
                            theme: theme,
                            task: visibleTasks[index],
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopTaskCard({
    required BuildContext context,
    required AppServices controller,
    required ThemeData theme,
    required TransferTask task,
  }) {
    final progressLabel = '${(task.progress * 100).round()}%';
    final colors = _progressColors(task.status);
    final completed = task.status == TransferTaskStatus.success;
    final infoLine = _cardInfoLine(task, DateTime.now(), hideDuplicateMessage: false);
    final infoStyle = TextStyle(
      fontSize: 11,
      color: theme.colorScheme.onSurfaceVariant,
    );
    final actionStyle = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: const Size(0, 24),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    );
    return GestureDetector(
      onTap: () => _showTaskDetails(context, task, desktop: true),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Checkbox(
                  value: _selectedTaskIds.contains(task.id),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (selected) => _toggleTaskSelection(
                    task.id,
                    selected ?? false,
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Text(
                    '${task.type == TransferTaskType.upload ? '上传' : '下载'} · ${task.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _labelForStatus(task.status),
                  style: TextStyle(
                    fontSize: 11,
                    color: _colorForStatus(context, task.status),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                if (task.status == TransferTaskStatus.interrupted) ...<Widget>[
                  TextButton(
                    style: actionStyle,
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
                  TextButton(
                    style: actionStyle,
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
                  TextButton(
                    style: actionStyle,
                    onPressed: task.status == TransferTaskStatus.failed ||
                            task.status == TransferTaskStatus.canceled
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
                  TextButton(
                    style: actionStyle,
                    onPressed: task.status == TransferTaskStatus.running ||
                            task.status == TransferTaskStatus.pending
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
            if (task.target != null)
              Padding(
                padding: const EdgeInsets.only(left: 34, bottom: 3),
                child: Text(
                  task.target!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: infoStyle,
                ),
              ),
            Row(
              children: <Widget>[
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: SizedBox(
                      height: 4,
                      child: LinearProgressIndicator(
                        value: task.progress.clamp(0.0, 1.0),
                        minHeight: 4,
                        color: completed ? const Color(0xFF34C759) : colors.last,
                        backgroundColor: completed
                            ? const Color(0x2634C759)
                            : const Color(0x29767680),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 32,
                  child: Text(
                    progressLabel,
                    textAlign: TextAlign.end,
                    style: infoStyle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 4,
                  child: _isLiveStatus(task)
                      ? ValueListenableBuilder<DateTime>(
                          valueListenable: _clock,
                          builder: (context, now, _) => Text(
                            _cardInfoLine(
                              task,
                              now,
                              hideDuplicateMessage: false,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: infoStyle,
                          ),
                        )
                      : Text(
                          infoLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: infoStyle,
                        ),
                ),
                if (task.isFinished) ...<Widget>[
                  const SizedBox(width: 12),
                  Text(
                    _finishedTime(task),
                    maxLines: 1,
                    style: infoStyle,
                  ),
                ],
              ],
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
    final infoLine = _cardInfoLine(task, DateTime.now(), hideDuplicateMessage: true);
    final hasActions = isInterrupted || canRetry || canCancel;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showTaskDetails(context, task, desktop: false),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(7),
                      gradient: LinearGradient(
                        colors: task.type == TransferTaskType.upload
                            ? const <Color>[
                                Color(0xFF5EEAD4),
                                Color(0xFF0EA5A4)
                              ]
                            : const <Color>[
                                Color(0xFF7DD3FC),
                                Color(0xFF2563EB)
                              ],
                      ),
                    ),
                    child: Icon(_iconForType(task.type),
                        size: 14, color: const Color(0xFF031B1A)),
                  ),
                  const SizedBox(width: 6),
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
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
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
                const SizedBox(height: 1),
                Text(
                  task.target!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 5),
              Row(
                children: <Widget>[
                  Expanded(
                    child: LinearProgressIndicator(
                      value: task.progress.clamp(0.0, 1.0),
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(999),
                      color: task.status == TransferTaskStatus.success
                          ? CupertinoDesktopTokens.success
                          : null,
                      backgroundColor: task.status == TransferTaskStatus.success
                          ? CupertinoDesktopTokens.success
                              .withValues(alpha: 0.16)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 40,
                    child: Text(
                      progressLabel,
                      maxLines: 1,
                      softWrap: false,
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              if (infoLine.isNotEmpty || hasActions) ...<Widget>[
                const SizedBox(height: 2),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _isLiveStatus(task)
                          ? ValueListenableBuilder<DateTime>(
                              valueListenable: _clock,
                              builder: (context, now, _) => Text(
                                _cardInfoLine(
                                  task,
                                  now,
                                  hideDuplicateMessage: true,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : Text(
                              infoLine,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                    ),
                    if (task.isFinished) ...<Widget>[
                      const SizedBox(width: 8),
                      Text(
                        _finishedTime(task),
                        maxLines: 1,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (isInterrupted) ...<Widget>[
                      SizedBox(
                        width: 26,
                        height: 26,
                        child: IconButton(
                          tooltip: '继续上传',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          onPressed: () {
                            controller.transferController
                                .resumeInterruptedUpload(task.id);
                            AppFeedback.showSnack(
                                context, '已继续上传 ${task.name}');
                          },
                          icon: const Icon(Icons.play_arrow_rounded, size: 18),
                        ),
                      ),
                      SizedBox(
                        width: 26,
                        height: 26,
                        child: IconButton(
                          tooltip: '放弃任务',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          onPressed: () {
                            controller.transferController
                                .abandonInterruptedUpload(task.id);
                            AppFeedback.showSnack(
                                context, '已放弃 ${task.name}');
                          },
                          icon:
                              const Icon(Icons.delete_outline_rounded, size: 16),
                        ),
                      ),
                    ],
                    if (canRetry)
                      SizedBox(
                        width: 26,
                        height: 26,
                        child: IconButton(
                          tooltip: '重试',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          onPressed: () {
                            controller.transferController.retryTask(task.id);
                            AppFeedback.showSnack(
                                context, '已重新开始 ${task.name}');
                          },
                          icon: const Icon(Icons.refresh_rounded, size: 16),
                        ),
                      ),
                    if (canCancel)
                      SizedBox(
                        width: 26,
                        height: 26,
                        child: IconButton(
                          tooltip: '取消传输',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          onPressed: () {
                            controller.transferController.cancelTask(task.id);
                            AppFeedback.showSnack(
                                context, '已取消 ${task.name}');
                          },
                          icon: const Icon(Icons.close_rounded, size: 16),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 任务详情 ----------

  Future<void> _showTaskDetails(
    BuildContext context,
    TransferTask task, {
    required bool desktop,
  }) {
    if (desktop) {
      return showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('任务详情'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: _buildTaskDetailBody(dialogContext, task),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: SingleChildScrollView(
            child: _buildTaskDetailBody(sheetContext, task),
          ),
        ),
      ),
    );
  }

  Widget _buildTaskDetailBody(BuildContext context, TransferTask task) {
    final theme = Theme.of(context);
    final queued = task.queuedTime;
    final started = task.startedAt;
    final finish = task.finishedAt;
    final end = finish ?? DateTime.now();
    final queueDuration =
        queued != null && started != null ? started.difference(queued) : null;
    final totalDuration = queued != null ? end.difference(queued) : null;
    final transferDuration =
        task.activeDurationMs > 0 ? task.activeDurationMs : null;
    final size = task.totalBytes ??
        (task.transferredBytes > 0 ? task.transferredBytes : null);
    final details = <(String, String)>[
      ('加入队列', formatTransferTimestamp(queued)),
      ('首次开始', formatTransferTimestamp(started)),
      ('最近开始', formatTransferTimestamp(task.lastStartedAt)),
      ('结束时间', formatTransferTimestamp(finish)),
      (
        '排队耗时',
        queueDuration == null
            ? transferUnknownPlaceholder
            : formatTransferDuration(queueDuration.inMilliseconds),
      ),
      (
        '总耗时',
        totalDuration == null
            ? transferUnknownPlaceholder
            : formatTransferDuration(totalDuration.inMilliseconds),
      ),
      ('传输耗时', formatTransferDuration(transferDuration)),
      ('平均速度', formatTransferSpeed(task.averageBytesPerSecond)),
      (
        '文件大小',
        size == null
            ? transferUnknownPlaceholder
            : formatTransferBytes(size),
      ),
      ('尝试次数', '${task.attemptCount} 次'),
      if (task.error != null && task.error!.isNotEmpty) ('失败原因', task.error!),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          task.name,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Icon(_iconForType(task.type), size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${task.type == TransferTaskType.upload ? '上传' : '下载'} · ${_labelForStatus(task.status)}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: _colorForStatus(context, task.status),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        if (task.target != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            task.target!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 8),
        for (final entry in details)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 76,
                  child: Text(
                    entry.$1,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    entry.$2,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
