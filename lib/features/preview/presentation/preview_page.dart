import 'package:flutter/material.dart';

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

    return Scaffold(
      appBar: AppBar(
        title: Text(args.fileName),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Card(
              child: ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('文件路径'),
                subtitle: Text(args.filePath),
              ),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: _PreviewBody(previewType: previewType, fileName: args.fileName),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({
    required this.previewType,
    required this.fileName,
  });

  final PreviewType previewType;
  final String fileName;

  @override
  Widget build(BuildContext context) {
    switch (previewType) {
      case PreviewType.image:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.image_outlined, size: 72),
            const SizedBox(height: 16),
            Text('图片预览区域', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('当前演示文件：$fileName'),
          ],
        );
      case PreviewType.pdf:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.picture_as_pdf_outlined, size: 72),
            const SizedBox(height: 16),
            Text('PDF 预览区域', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('这里后续可替换为真实 PDF 渲染组件'),
          ],
        );
      case PreviewType.text:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('文本预览', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  '文件：$fileName\n\n# 静态预览内容\n\n- 当前页面只用于演示文本类文件预览\n- 后续可以接真实下载与内容读取逻辑\n- 这里也可以继续扩展编码、大小限制和错误态展示',
                ),
              ),
            ),
          ],
        );
      case PreviewType.unsupported:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.block_outlined, size: 72),
            const SizedBox(height: 16),
            Text('暂不支持预览', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('文件：$fileName'),
          ],
        );
    }
  }
}
