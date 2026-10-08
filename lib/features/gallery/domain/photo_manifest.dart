import 'dart:convert';

import 'photo_entry.dart';

/// OSS 清单对象 `.gallery/index/photos.json` 的编解码。
class PhotoManifest {
  const PhotoManifest({
    required this.version,
    required this.scannedAt,
    required this.needsRepair,
    required this.entries,
    this.formatVersion = 0,
  });

  final int version;
  final DateTime? scannedAt;
  final bool needsRepair;
  final List<PhotoEntry> entries;

  /// 清单生成器版本。0 = 旧版生成（拍摄时间解析有缺陷，不允许被
  /// 新设备直接采纳）；2 = 文件头优先解析修复后生成；
  /// 3 = 无 EXIF 时回退文件名/目录日期推断生成；
  /// 4 = 上传路径补齐同一推断（修复存量条目拍摄时间等于上传时间）。
  final int formatVersion;

  /// 当前生成器写出的格式版本。
  static const int currentFormatVersion = 4;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'fv': formatVersion,
        'scannedAt': scannedAt?.millisecondsSinceEpoch,
        'needsRepair': needsRepair,
        'photos': entries
            .map((entry) => <String, Object?>{
                  'key': entry.key,
                  'media': entry.mediaType == PhotoMediaType.video ? 1 : 0,
                  'takenAt': entry.takenAt.millisecondsSinceEpoch,
                  'size': entry.size,
                  'dir': entry.directory,
                  if (entry.thumbKey != null) 'thumb': entry.thumbKey,
                  if (entry.modifiedMs != null) 'mtime': entry.modifiedMs,
                  if (entry.width != null) 'w': entry.width,
                  if (entry.height != null) 'h': entry.height,
                  if (entry.latitude != null) 'lat': entry.latitude,
                  if (entry.longitude != null) 'lon': entry.longitude,
                  if (entry.device != null) 'dev': entry.device,
                })
            .toList(),
      };

  String encode() => jsonEncode(toJson());

  /// 解析失败（JSON 损坏、结构不完整）时抛出 [FormatException]，
  /// 由调用方标记索引待修复。
  static PhotoManifest decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('清单结构不是对象');
    final photos = decoded['photos'];
    if (photos is! List) throw const FormatException('清单缺少照片列表');
    final entries = <PhotoEntry>[];
    for (final item in photos) {
      if (item is! Map) continue;
      final key = item['key'];
      final takenAt = item['takenAt'];
      final size = item['size'];
      final dir = item['dir'];
      if (key is! String ||
          key.isEmpty ||
          takenAt is! num ||
          size is! num ||
          dir is! String) {
        continue;
      }
      entries.add(PhotoEntry(
        key: key,
        mediaType: (item['media'] as num? ?? 0) == 1
            ? PhotoMediaType.video
            : PhotoMediaType.image,
        takenAt:
            DateTime.fromMillisecondsSinceEpoch(takenAt.toInt()),
        size: size.toInt(),
        directory: dir,
        thumbKey: item['thumb'] is String ? item['thumb'] as String : null,
        modifiedMs: item['mtime'] is num ? (item['mtime'] as num).toInt() : null,
        width: item['w'] is num ? (item['w'] as num).toInt() : null,
        height: item['h'] is num ? (item['h'] as num).toInt() : null,
        latitude: item['lat'] is num ? (item['lat'] as num).toDouble() : null,
        longitude: item['lon'] is num ? (item['lon'] as num).toDouble() : null,
        device: item['dev'] is String ? item['dev'] as String : null,
      ));
    }
    return PhotoManifest(
      version: decoded['version'] is num
          ? (decoded['version'] as num).toInt()
          : 0,
      formatVersion: decoded['fv'] is num
          ? (decoded['fv'] as num).toInt()
          : 0,
      scannedAt: decoded['scannedAt'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (decoded['scannedAt'] as num).toInt())
          : null,
      needsRepair: decoded['needsRepair'] == true,
      entries: entries,
    );
  }
}
