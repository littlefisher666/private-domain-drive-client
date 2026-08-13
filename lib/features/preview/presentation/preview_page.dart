import 'package:flutter/material.dart';

import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../workspace/domain/file_item.dart';
import '../domain/preview_type.dart';

class PreviewPageArguments {
  const PreviewPageArguments({
    required this.fileName,
    required this.filePath,
  });

  final String fileName;
  final String filePath;
}

class PreviewPage extends StatelessWidget {
  const PreviewPage({super.key, this.arguments});

  final PreviewPageArguments? arguments;

  @override
  Widget build(BuildContext context) {
    final args = arguments ??
        const PreviewPageArguments(
          fileName: 'preview.txt',
          filePath: 'shared/preview.txt',
        );
    final previewType = PreviewTypeResolver.fromFileName(args.fileName);
    final controller = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(args.fileName, style: theme.textTheme.titleMedium),
            Text(
              args.filePath,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: <Widget>[
          if (controller.capabilities.download)
            IconButton(
              tooltip: '下载',
              onPressed: () async {
                try {
                  await controller.mockDownload(
                    FileItem(
                      path: args.filePath,
                      name: args.fileName,
                      isDirectory: false,
                    ),
                  );
                  if (context.mounted) {
                    AppFeedback.showSnack(context, '已开始下载 ${args.fileName}');
                  }
                } catch (error) {
                  if (context.mounted) {
                    AppFeedback.showSnack(
                      context,
                      error.toString().replaceFirst('Bad state: ', ''),
                    );
                  }
                }
              },
              icon: const Icon(Icons.download_outlined),
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _PreviewBody(
                previewType: previewType,
                fileName: args.fileName,
                textContent: controller.mockPreviewText(args.fileName),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({
    required this.previewType,
    required this.fileName,
    required this.textContent,
  });

  final PreviewType previewType;
  final String fileName;
  final String textContent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    switch (previewType) {
      case PreviewType.image:
        return Column(
          children: <Widget>[
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[Color(0xFF99F6E4), Color(0xFF38BDF8), Color(0xFF818CF8)],
                  ),
                ),
                child: const Center(
                  child: Icon(Icons.image_outlined, size: 72, color: Color(0xFF0F172A)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('图片预览', style: theme.textTheme.titleMedium),
            Text(
              '文件：$fileName',
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        );
      case PreviewType.pdf:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('PDF 预览', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: ListView(
                  children: <Widget>[
                    Text(fileName, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    Text(
                      '正在展示 PDF 预览区域。可从文件列表进入，下载将创建传输任务。',
                      style: theme.textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      case PreviewType.text:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('文本预览', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(textContent, style: theme.textTheme.bodyLarge),
                ),
              ),
            ),
          ],
        );
      case PreviewType.unsupported:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.block_outlined, size: 56, color: scheme.error),
              const SizedBox(height: 12),
              Text('暂不支持预览', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                '文件：$fileName\n当前类型仅支持下载。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        );
    }
  }
}
