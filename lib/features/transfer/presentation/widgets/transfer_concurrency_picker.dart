import 'package:flutter/material.dart';

import '../../../../shared/state/app_services.dart';
import '../../../../shared/widgets/app_feedback.dart';

/// 总传输并发数选择弹窗：桌面头部入口与移动端更多菜单共用，
/// 写入同一份队列配置。
Future<void> showTransferConcurrencyPicker(
  BuildContext context,
  AppServices controller,
) async {
  final current = controller.transferQueue.transferConcurrency;
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
        for (var option = 1; option <= 5; option++)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(option),
            child: Row(
              children: <Widget>[
                Expanded(child: Text('$option 个并发')),
                if (option == current) const Icon(Icons.check, size: 18),
              ],
            ),
          ),
      ],
    ),
  );
  if (value == null) return;
  await controller.transferQueue.setTransferConcurrency(value);
  if (context.mounted) {
    AppFeedback.showSnack(context, '并发数已设为 $value');
  }
}
