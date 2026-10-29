import 'package:flutter/material.dart';

import '../../core/errors/app_error.dart';

class AppFeedback {
  AppFeedback._();

  /// 面向用户的错误文案：业务异常使用自带文案，未知异常统一为通用提示。
  static String errorMessage(Object error) => userFacingErrorMessage(error);

  /// 展示用户文案，同时把完整异常与堆栈写入调试日志。
  static void showError(
    BuildContext context,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    debugPrint('操作失败：$error\n${stackTrace ?? StackTrace.current}');
    showSnack(context, errorMessage(error));
  }

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
