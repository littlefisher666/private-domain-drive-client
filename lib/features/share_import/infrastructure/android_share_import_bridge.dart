import 'dart:async';

import 'package:flutter/services.dart';

import '../../../shared/state/app_controller.dart';

/// Android 原生分享 Intent 与 Flutter 确认上传页之间的桥接。
class AndroidShareImportBridge {
  AndroidShareImportBridge._();

  static const _methods = MethodChannel('private_domain_drive/share_import');
  static const _events =
      EventChannel('private_domain_drive/share_import_events');

  static Stream<List<ShareImportItem>> get incomingItems =>
      _events.receiveBroadcastStream().map((event) => _parseItems(event));

  static Future<List<ShareImportItem>> takePendingItems() async {
    try {
      final value = await _methods.invokeMethod<Object?>('takePendingItems');
      return _parseItems(value);
    } on MissingPluginException {
      return const <ShareImportItem>[];
    }
  }

  static List<ShareImportItem> _parseItems(Object? value) {
    if (value is! List) return const <ShareImportItem>[];
    return value
        .whereType<Map<Object?, Object?>>()
        .map((raw) {
          final item = Map<Object?, Object?>.from(raw);
          final path = item['path']?.toString() ?? '';
          return ShareImportItem(
            id: item['id']?.toString() ?? path,
            name: item['name']?.toString() ?? '未命名文件',
            size: (item['size'] as num?)?.toInt() ?? 0,
            localPath: path,
          );
        })
        .where((item) => item.localPath.isNotEmpty)
        .toList(growable: false);
  }
}
