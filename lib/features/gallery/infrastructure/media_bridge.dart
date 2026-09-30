import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 视频/媒体基础设施桥：截帧与媒体元数据。
///
/// Android 使用 MediaMetadataRetriever，macOS 使用 AVFoundation，
/// 均由应用级 MethodChannel 提供，截帧结果为 JPEG 字节。
class MediaBridge {
  MediaBridge();

  static const _channel =
      MethodChannel('private_domain_drive/media');

  /// 截取视频某一帧，返回 JPEG 字节；失败返回 null（不阻塞上传）。
  Future<List<int>?> captureVideoThumbnail(
    String videoPath, {
    int maxWidth = 512,
  }) async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'videoThumbnail',
        <String, Object?>{
          'path': videoPath,
          'maxWidth': maxWidth,
        },
      );
      if (result == null) return null;
      return result.cast<int>();
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 读取视频拍摄时间（媒体元数据），缺失或失败返回 null。
  Future<DateTime?> readVideoTakenAt(String videoPath) async {
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('videoMetadata', <String, Object?>{
        'path': videoPath,
      });
      final milliseconds = result?['takenAtMs'];
      if (milliseconds is num && milliseconds > 0) {
        return DateTime.fromMillisecondsSinceEpoch(milliseconds.toInt());
      }
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// macOS 剪贴板桥：复制本地图片文件、读取剪贴板图片数据。
/// 非 macOS 平台调用一律返回不可用结果。
class ClipboardBridge {
  ClipboardBridge();

  static const _channel =
      MethodChannel('private_domain_drive/clipboard');

  /// 将本地图片文件写入系统剪贴板（每个文件一个剪贴板条目）。
  Future<bool> copyImageFiles(Iterable<String> filePaths) async {
    if (!Platform.isMacOS) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'copyImageFiles',
            <String, Object?>{'paths': filePaths.toList()},
          ) ==
          true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 读取剪贴板中的图片数据；无图片内容返回 null。
  Future<ClipboardImage?> readImage() async {
    if (!Platform.isMacOS) return null;
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('readImage');
      if (result == null) return null;
      final bytes = result['bytes'];
      final ext = result['ext'];
      if (bytes is! List || bytes.isEmpty) return null;
      return ClipboardImage(
        bytes: bytes.cast<int>(),
        extension: ext is String && ext.isNotEmpty ? ext : 'png',
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

class ClipboardImage {
  const ClipboardImage({required this.bytes, required this.extension});

  final List<int> bytes;
  final String extension;
}
