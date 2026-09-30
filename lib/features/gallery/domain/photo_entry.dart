enum PhotoMediaType { image, video }

/// 照片索引条目：与 OSS 清单对象及本地 SQLite 副本共用同一模型。
class PhotoEntry {
  const PhotoEntry({
    required this.key,
    required this.mediaType,
    required this.takenAt,
    required this.size,
    required this.directory,
    this.thumbKey,
    this.modifiedMs,
    this.width,
    this.height,
    this.latitude,
    this.longitude,
    this.device,
  });

  /// OSS 对象 key（含会话根前缀）。
  final String key;
  final PhotoMediaType mediaType;

  /// 拍摄时间（EXIF / 媒体元数据优先，缺失时为文件修改时间）。
  final DateTime takenAt;
  final int size;

  /// 所在目录（以 / 结尾的前缀）。
  final String directory;

  /// 视频截帧缩略图对象 key；图片条目与无缩略图视频为 null。
  final String? thumbKey;

  /// 对象最后修改时间毫秒值，用于识别对象变化。
  final int? modifiedMs;

  /// 图片像素尺寸（EXIF 或文件头可得时记录）。
  final int? width;
  final int? height;

  /// 拍摄位置（EXIF GPS，度数；无定位信息为 null）。
  final double? latitude;
  final double? longitude;

  /// 上传设备（上传时记录的平台名；全量扫描无法得知为 null）。
  final String? device;

  String get name => key.substring(directory.length);

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  Map<String, Object?> toRow() => <String, Object?>{
        'key': key,
        'media': mediaType == PhotoMediaType.video ? 1 : 0,
        'taken_at': takenAt.millisecondsSinceEpoch,
        'size': size,
        'dir': directory,
        'thumb_key': thumbKey,
        'mtime': modifiedMs,
        'width': width,
        'height': height,
        'lat': latitude,
        'lon': longitude,
        'device': device,
      };

  static PhotoEntry fromRow(Map<String, Object?> row) {
    return PhotoEntry(
      key: row['key'] as String,
      mediaType: (row['media'] as int) == 1
          ? PhotoMediaType.video
          : PhotoMediaType.image,
      takenAt:
          DateTime.fromMillisecondsSinceEpoch(row['taken_at'] as int),
      size: row['size'] as int,
      directory: row['dir'] as String,
      thumbKey: row['thumb_key'] as String?,
      modifiedMs: row['mtime'] as int?,
      width: row['width'] as int?,
      height: row['height'] as int?,
      latitude: (row['lat'] as num?)?.toDouble(),
      longitude: (row['lon'] as num?)?.toDouble(),
      device: row['device'] as String?,
    );
  }
}

/// 索引元信息：版本号、最后扫描时间与待修复标记。
class PhotoIndexMeta {
  const PhotoIndexMeta({
    required this.version,
    required this.scannedAt,
    required this.needsRepair,
  });

  final int version;
  final DateTime? scannedAt;
  final bool needsRepair;

  Map<String, Object?> toRow() => <String, Object?>{
        'id': 1,
        'version': version,
        'scanned_at': scannedAt?.millisecondsSinceEpoch,
        'needs_repair': needsRepair ? 1 : 0,
      };
}
