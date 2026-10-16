import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/share_import_models.dart';

/// 分享导入信封事件：批次开始 / 单项到达 / 批次完成。
sealed class ShareImportEvent {
  const ShareImportEvent({required this.batchId});

  final String batchId;
}

/// 批次开始：[total] 为原生端解析出的分享文件总数。
class ShareImportBatchStart extends ShareImportEvent {
  const ShareImportBatchStart({required super.batchId, required this.total});

  final int total;
}

/// 单个文件复制成功。
class ShareImportItemEvent extends ShareImportEvent {
  const ShareImportItemEvent({required super.batchId, required this.item});

  final ShareImportItem item;
}

/// 批次结束：附成功/失败计数；复制失败的单项不会推送 item 事件。
class ShareImportBatchDone extends ShareImportEvent {
  const ShareImportBatchDone({
    required super.batchId,
    required this.succeeded,
    required this.failed,
  });

  final int succeeded;
  final int failed;
}

/// Android 原生分享 Intent 与 Flutter 之间的桥接。
///
/// 事件为「批次开始 → 逐项推送 → 批次完成」的信封格式；未知事件类型
/// 忽略并打日志，保持向前兼容。
class AndroidShareImportBridge {
  AndroidShareImportBridge._();

  static const _methods = MethodChannel('private_domain_drive/share_import');
  static const _events =
      EventChannel('private_domain_drive/share_import_events');

  static Stream<ShareImportEvent> get events => _events
      .receiveBroadcastStream()
      .map(_parseEvent)
      .where((event) => event != null)
      .map((event) => event!);

  /// 冷启动兜底：取走原生缓冲中已完整的批次（取走后原生侧移除）。
  static Future<List<ShareImportCompleteBatch>> takePendingBatches() async {
    try {
      final value = await _methods.invokeMethod<Object?>('takePendingItems');
      if (value is! List) return const <ShareImportCompleteBatch>[];
      return value
          .whereType<Map<Object?, Object?>>()
          .map(_parseCompleteBatch)
          .whereType<ShareImportCompleteBatch>()
          .toList(growable: false);
    } on MissingPluginException {
      return const <ShareImportCompleteBatch>[];
    }
  }

  @visibleForTesting
  static ShareImportEvent? parseEvent(Object? value) => _parseEvent(value);

  static ShareImportEvent? _parseEvent(Object? value) {
    if (value is! Map) {
      return null;
    }
    final event = Map<Object?, Object?>.from(value);
    final batchId = event['batchId']?.toString() ?? '';
    switch (event['type']) {
      case 'batch_start':
        return ShareImportBatchStart(
          batchId: batchId,
          total: (event['total'] as num?)?.toInt() ?? 0,
        );
      case 'item':
        final rawItem = event['item'];
        if (rawItem is! Map) return null;
        final item = _parseItem(Map<Object?, Object?>.from(rawItem));
        if (item == null) return null;
        return ShareImportItemEvent(batchId: batchId, item: item);
      case 'batch_done':
        return ShareImportBatchDone(
          batchId: batchId,
          succeeded: (event['succeeded'] as num?)?.toInt() ?? 0,
          failed: (event['failed'] as num?)?.toInt() ?? 0,
        );
      default:
        if (kDebugMode) {
          debugPrint('[share-import] 忽略未知分享事件类型: ${event['type']}');
        }
        return null;
    }
  }

  static ShareImportCompleteBatch? _parseCompleteBatch(Map<Object?, Object?> raw) {
    final batch = Map<Object?, Object?>.from(raw);
    final batchId = batch['batchId']?.toString() ?? '';
    final rawItems = batch['items'];
    if (batchId.isEmpty || rawItems is! List) return null;
    final items = rawItems
        .whereType<Map<Object?, Object?>>()
        .map((item) => _parseItem(Map<Object?, Object?>.from(item)))
        .whereType<ShareImportItem>()
        .toList(growable: false);
    return ShareImportCompleteBatch(
      batchId: batchId,
      items: items,
      succeeded: (batch['succeeded'] as num?)?.toInt() ?? items.length,
      failed: (batch['failed'] as num?)?.toInt() ?? 0,
    );
  }

  static ShareImportItem? _parseItem(Map<Object?, Object?> raw) {
    final item = Map<Object?, Object?>.from(raw);
    final path = item['path']?.toString() ?? '';
    if (path.isEmpty) return null;
    return ShareImportItem(
      id: item['id']?.toString() ?? path,
      name: item['name']?.toString() ?? '未命名文件',
      size: (item['size'] as num?)?.toInt() ?? 0,
      localPath: path,
    );
  }
}
