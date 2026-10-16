import 'package:flutter/material.dart';

/// 相册加载失败视图：错误信息 + 重试按钮。
class GalleryPageErrorView extends StatelessWidget {
  const GalleryPageErrorView({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.cloud_off_outlined,
              size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(message, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
