import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
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
              controller.displayPath(args.filePath),
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
                  final directory =
                      await FilePicker.getDirectoryPath();
                  if (directory == null) return;
                  controller.enqueueDownload(
                    FileItem(
                      path: args.filePath,
                      name: args.fileName,
                      isDirectory: false,
                    ),
                    targetDirectory: directory,
                  );
                  if (context.mounted) {
                    AppFeedback.showSnack(context, '已加入下载队列：${args.fileName}');
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
                filePath: args.filePath,
                imageLoader: controller.loadImagePreview,
                textContent: '暂不支持在线读取此文件内容，请下载后查看。',
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
    required this.filePath,
    required this.imageLoader,
    required this.textContent,
  });

  final PreviewType previewType;
  final String fileName;
  final String filePath;
  final Future<List<int>> Function(FileItem item) imageLoader;
  final String textContent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    switch (previewType) {
      case PreviewType.image:
        return _ImagePreviewBody(
          item: FileItem(
            path: filePath,
            name: fileName,
            isDirectory: false,
          ),
          loader: imageLoader,
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

class _ImagePreviewBody extends StatefulWidget {
  const _ImagePreviewBody({required this.item, required this.loader});

  final FileItem item;
  final Future<List<int>> Function(FileItem item) loader;

  @override
  State<_ImagePreviewBody> createState() => _ImagePreviewBodyState();
}

class _ImagePreviewBodyState extends State<_ImagePreviewBody> {
  late Future<List<int>> _imageFuture;

  @override
  void initState() {
    super.initState();
    _imageFuture = widget.loader(widget.item);
  }

  @override
  void didUpdateWidget(covariant _ImagePreviewBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path) {
      _imageFuture = widget.loader(widget.item);
    }
  }

  void _retry() {
    setState(() => _imageFuture = widget.loader(widget.item));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      children: <Widget>[
        Expanded(
          child: Container(
            width: double.infinity,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              color: scheme.surfaceContainerHighest,
            ),
            child: FutureBuilder<List<int>>(
              future: _imageFuture,
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                if (snapshot.connectionState == ConnectionState.done &&
                    bytes != null &&
                    bytes.isNotEmpty) {
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Image.memory(
                      Uint8List.fromList(bytes),
                      fit: BoxFit.contain,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (_, __, ___) => _errorState(theme),
                    ),
                  );
                }
                if (snapshot.hasError) return _errorState(theme);
                return const CircularProgressIndicator();
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('图片预览', style: theme.textTheme.titleMedium),
        Text(
          '文件：${widget.item.name}',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _errorState(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.broken_image_outlined, size: 72),
        const SizedBox(height: 12),
        Text('图片预览加载失败', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _retry, child: const Text('重试')),
      ],
    );
  }
}
