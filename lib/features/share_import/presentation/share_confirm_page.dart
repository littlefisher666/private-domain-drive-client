import 'package:flutter/material.dart';

import '../../../app/router/route_names.dart';
import '../../../core/utils/file_size_formatter.dart';
import '../../../shared/state/app_scope.dart';
import '../../../shared/widgets/app_feedback.dart';

class ShareConfirmPage extends StatelessWidget {
  const ShareConfirmPage({super.key});

  Future<void> _pickFolder(BuildContext context) async {
    final controller = AppScope.read(context);
    final dirs = controller.sidebarDirectories;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              const ListTile(title: Text('选择上传目录')),
              ...dirs.map(
                (path) => ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(path),
                  onTap: () => Navigator.pop(context, path),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (selected != null) {
      controller.setShareTargetPath(selected);
    }
  }

  Future<void> _confirm(BuildContext context) async {
    final controller = AppScope.read(context);
    if (!controller.capabilities.upload) {
      await AppFeedback.confirm(
        context,
        title: '无法上传',
        message: '当前账号没有上传权限。',
        confirmLabel: '知道了',
      );
      return;
    }

    try {
      await controller.confirmShareUpload();
      if (context.mounted) {
        AppFeedback.showSnack(context, '已创建上传任务');
        Navigator.of(context).pushNamedAndRemoveUntil(
          RouteNames.home,
          (route) => false,
          arguments: 1,
        );
      }
    } catch (error) {
      if (context.mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final items = controller.pendingShareItems;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('确认上传'),
        actions: <Widget>[
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  '分享进入后先选目录，再确认上传。确认后会写入文件列表和传输任务。',
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                title: const Text('目标文件夹'),
                subtitle: Text(controller.shareTargetPath),
                trailing: OutlinedButton(
                  onPressed: () => _pickFolder(context),
                  child: const Text('更改'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: <Widget>[
                  ListTile(
                    title: const Text('待上传列表'),
                    trailing: Text('${items.length} 项'),
                  ),
                  const Divider(height: 1),
                  if (items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('没有待上传内容'),
                    )
                  else
                    ...items.map(
                      (item) => ListTile(
                        leading: const Icon(Icons.insert_drive_file_outlined),
                        title: Text(item.name),
                        subtitle: Text(FileSizeFormatter.format(item.size)),
                        trailing: IconButton(
                          tooltip: '移除',
                          onPressed: () => controller.removeShareItem(item.id),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (!controller.capabilities.upload) ...<
              Widget
            >[
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    '当前账号没有上传权限。',
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: items.isEmpty ? null : () => _confirm(context),
                    child: const Text('确认上传'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
