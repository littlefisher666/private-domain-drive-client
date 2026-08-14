import 'package:flutter/material.dart';

class AppFeedback {
  AppFeedback._();

  static void showSnack(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static Future<String?> promptText(
    BuildContext context, {
    required String title,
    String? initialValue,
    String confirmLabel = '确定',
    String? hintText,
  }) async {
    final controller = TextEditingController(text: initialValue ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(hintText: hintText),
            onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text.trim()),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    // showDialog 返回时退出动画可能仍在重建 TextField，延后释放避免
    // TextEditingController 在 widget 尚未卸载时被再次访问。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (result == null || result.isEmpty) {
      return null;
    }
    return result;
  }

  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = '确定',
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    )
                  : null,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }
}
