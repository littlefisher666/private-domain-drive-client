import 'dart:io';

import 'package:flutter/services.dart';

const _windowChannel = MethodChannel('private_domain_drive/window');

/// 双击标题栏触发 macOS 原生 zoom（最大化/还原）。
Future<void> toggleWindowZoom() async {
  if (!Platform.isMacOS) return;
  try {
    await _windowChannel.invokeMethod<void>('performZoom');
  } on MissingPluginException {
    // 桥未注册时忽略。
  }
}
