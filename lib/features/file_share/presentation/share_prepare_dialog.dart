import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/utils/file_size_formatter.dart';
import '../domain/file_share_models.dart';

/// 分享准备进度弹窗：展示下载进度并允许取消；进度置空后自动关闭。
class SharePrepareDialog extends StatefulWidget {
  const SharePrepareDialog({
    super.key,
    required this.progress,
    required this.onCancel,
  });

  final ValueListenable<ShareProgress?> progress;
  final VoidCallback onCancel;

  @override
  State<SharePrepareDialog> createState() => _SharePrepareDialogState();
}

class _SharePrepareDialogState extends State<SharePrepareDialog> {
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_closeWhenFinished);
    // 准备可能在弹窗首次构建前就已结束，此时进度已置空。
    if (widget.progress.value == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _closeWhenFinished());
    }
  }

  @override
  void didUpdateWidget(SharePrepareDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_closeWhenFinished);
      widget.progress.addListener(_closeWhenFinished);
    }
  }

  @override
  void dispose() {
    widget.progress.removeListener(_closeWhenFinished);
    super.dispose();
  }

  void _closeWhenFinished() {
    if (_closing || widget.progress.value != null || !mounted) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('正在准备分享'),
        content: ValueListenableBuilder<ShareProgress?>(
          valueListenable: widget.progress,
          builder: (context, progress, _) {
            if (progress == null) {
              return const SizedBox(
                width: 280,
                child: LinearProgressIndicator(),
              );
            }
            final total = progress.totalBytes;
            return SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    progress.isBatch
                        ? '第 ${progress.fileIndex}/${progress.fileCount} 个：'
                            '${progress.fileName}'
                        : progress.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: progress.fraction),
                  const SizedBox(height: 8),
                  Text(
                    '已传输 ${FileSizeFormatter.format(progress.receivedBytes)}'
                    ' / ${total == null ? '未知大小' : FileSizeFormatter.format(total)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            );
          },
        ),
        actions: <Widget>[
          TextButton(
            onPressed: widget.onCancel,
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }
}
