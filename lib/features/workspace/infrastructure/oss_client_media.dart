part of 'oss_client.dart';

/// 头部 EXIF 探测档位。JPEG 段完整时提前结束不会读满；HEIC 的 EXIF
/// item 前可能有较大的元数据区（实测有文件在 33KB 处），需保留大档位。
const _jpegExifProbeSizes = <int>[
  2 * 1024,
  4 * 1024,
  8 * 1024,
  16 * 1024,
  32 * 1024,
  64 * 1024,
  128 * 1024,
];

/// 图片 EXIF 解析结果：拍摄时间、GPS 坐标与像素尺寸。
class ImageExifInfo {
  const ImageExifInfo({
    this.takenAt,
    this.latitude,
    this.longitude,
    this.width,
    this.height,
  });

  final DateTime? takenAt;
  final double? latitude;
  final double? longitude;
  final int? width;
  final int? height;
}

/// OssClient 的媒体处理实现：缩略图/预览/视频截帧下载与图片 EXIF 解析。
mixin _OssClientMedia on _OssClientCore {
  Future<List<int>> downloadThumbnail(
    String path,
    UserSession session, {
    int width = ImageThumbnailSpec.size,
    int height = ImageThumbnailSpec.size,
  }) async {
    if (width <= 0 || height <= 0 || width > 1024 || height > 1024) {
      throw ArgumentError('缩略图尺寸必须在 1 到 1024 之间');
    }
    return _getProcessedObject(
      path,
      session,
      maxBytes: 4 * 1024 * 1024,
      process: ImageThumbnailSpec.process(width: width, height: height),
    );
  }

  /// 读取用于详情页展示的图片预览，仍由 OSS 图片处理压缩原图尺寸。
  Future<List<int>> downloadImagePreview(
    String path,
    UserSession session, {
    int width = ImageThumbnailSpec.previewSize,
    int height = ImageThumbnailSpec.previewSize,
  }) async {
    if (width <= 0 || height <= 0 || width > 2048 || height > 2048) {
      throw ArgumentError('图片预览尺寸必须在 1 到 2048 之间');
    }
    return _getProcessedObject(
      path,
      session,
      maxBytes: 8 * 1024 * 1024,
      process: ImageThumbnailSpec.process(width: width, height: height),
    );
  }

  /// 通过 OSS 视频截帧获取视频首帧缩略图（服务端处理，无需下载原视频）。
  Future<List<int>> downloadVideoSnapshot(
    String path,
    UserSession session,
  ) async {
    return _getProcessedObject(
      path,
      session,
      maxBytes: 4 * 1024 * 1024,
      process: 'video/snapshot,t_0,f_jpg,w_512,m_fast',
    );
  }

  /// 通过 OSS 图片处理与 JPEG 文件头探测读取图片 EXIF。
  /// 不支持或不含 EXIF 的图片返回空信息。
  Future<ImageExifInfo> readImageExif(
    String path,
    UserSession session,
  ) async {
    // 文件头优先：JPEG 的拍摄时间/GPS/尺寸、PNG 的尺寸与 HEIC 的
    // 拍摄时间都能从头部 Range 请求解析，避免多余的图片处理请求；
    // 解析不出拍摄时间再走 image/exif 兜底（OSS 该接口不支持 HEIC）。
    final header = <int>[];
    ImageExifInfo? headerInfo;
    var isJpeg = false;
    for (final targetSize in _jpegExifProbeSizes) {
      List<int> chunk;
      try {
        chunk = await _getObjectRange(
          path,
          session,
          startByte: header.length,
          endByte: targetSize - 1,
        );
      } on AppError {
        // 首次探测失败按原逻辑抛出；后续探测失败说明起点已越过
        // 文件末尾（文件大小恰为上一档探测边界），按读满处理。
        if (header.isEmpty) rethrow;
        chunk = const <int>[];
      }
      header.addAll(chunk);
      final info = _parseImageHeaderInfo(header);
      isJpeg = header.length >= 2 && header[0] == 0xff && header[1] == 0xd8;
      if (info != null) {
        if (info.takenAt != null) return info;
        if (!isJpeg) {
          // PNG 等格式头部已给出全部可得信息，格式本身不携带 EXIF。
          return info;
        }
        headerInfo = info;
      }
      // JPEG 的所有 EXIF 都位于 SOS（图像数据开始）之前；已越过该位置
      // 仍未找到日期，即可确定没有可用 EXIF，无需读满最大范围。
      if (isJpeg && _isJpegMetadataComplete(header)) break;
      // 已到文件末尾仍未读到拍摄日期，无需继续扩大范围。
      if (header.length < targetSize) break;
    }
    DateTime? takenAt;
    // OSS 的 image/exif 仅支持 JPEG；HEIC 等格式服务端会拒绝
    // （InvalidArgument），头部解析不出就不再请求。
    if (isJpeg) {
      try {
        final bytes = await _getProcessedObject(
          path,
          session,
          maxBytes: 128 * 1024,
          process: 'image/exif',
        );
        final value = jsonDecode(utf8.decode(bytes));
        if (value is Map) {
          for (final key in <String>[
            'DateTimeOriginal',
            'DateTimeDigitized',
            'DateTime',
          ]) {
            final raw = _findExifValue(value, key);
            if (raw is! String) continue;
            final parsed = _parseExifDate(raw);
            if (parsed != null) {
              takenAt = parsed;
              break;
            }
          }
        }
      } catch (_) {
        // 图片处理接口失败或格式不支持时，保留文件头解析结果。
      }
    }
    return ImageExifInfo(
      takenAt: takenAt ?? headerInfo?.takenAt,
      latitude: headerInfo?.latitude,
      longitude: headerInfo?.longitude,
      width: headerInfo?.width,
      height: headerInfo?.height,
    );
  }

  /// 解析本地图片文件的文件头（前 256 KB），提取拍摄时间、GPS 与尺寸。
  /// 解析失败或格式不支持时返回空信息，由调用方回退文件时间。
  Future<ImageExifInfo> readLocalImageExif(File file) async {
    try {
      final length = await file.length();
      final header = await file.openRead(0, min(length, 256 * 1024)).fold(
            <int>[],
            (buffer, chunk) => buffer..addAll(chunk),
          );
      return _parseImageHeaderInfo(header) ?? const ImageExifInfo();
    } catch (_) {
      return const ImageExifInfo();
    }
  }
}

DateTime? _parseExifDate(String value) {
  final trimmed = value.trim();
  // EXIF 常见格式为 2026:09:10 14:30:00。部分相册工具会在日期串末尾
  // 追加非标准文本（实测出现"2019:06:14 12:20:38下午"），只取首个
  // 完整的日期时间片段解析。
  final match = RegExp(
    r'(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(trimmed);
  if (match != null) {
    return DateTime(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
      int.parse(match[4]!),
      int.parse(match[5]!),
      int.parse(match[6]!),
    );
  }
  return DateTime.tryParse(trimmed);
}

Object? _findExifValue(Map<dynamic, dynamic> values, String targetKey) {
  for (final entry in values.entries) {
    if (entry.key == targetKey) return entry.value;
    if (entry.value is Map) {
      final nested =
          _findExifValue(entry.value as Map<dynamic, dynamic>, targetKey);
      if (nested != null) return nested;
    }
  }
  return null;
}

ImageExifInfo? _parseImageHeaderInfo(List<int> bytes) {
  final jpeg = _parseJpegSegments(bytes);
  if (jpeg != null) return jpeg;
  // HEIC/HEIF：EXIF 位于 ftyp 之后的 Exif 盒内（OSS 图片处理不支持
  // HEIC 的 image/exif，只能客户端解析）。
  if (_isHeifContainer(bytes)) {
    final heif = _parseHeifExif(bytes);
    if (heif != null) return heif;
  }
  // PNG：固定 8 字节签名 + IHDR 宽高位于第 16-24 字节。
  if (bytes.length >= 24 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    int read32(int offset) =>
        (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    return ImageExifInfo(width: read32(16), height: read32(20));
  }
  return null;
}

ImageExifInfo? _parseJpegSegments(List<int> bytes) {
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return null;
  var offset = 2;
  DateTime? takenAt;
  int? width;
  int? height;
  double? latitude;
  double? longitude;
  var foundExif = false;
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] != 0xff) {
      offset++;
      continue;
    }
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) break;
    final marker = bytes[offset++];
    if (marker == 0xd9 || marker == 0xda) break;
    if ((marker >= 0xd0 && marker <= 0xd7) || marker == 0x01) continue;
    if (offset + 2 > bytes.length) break;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2) break;
    // Range 探测只有前几十 KB，相机照片的 APP1/EXIF 段可长达 64KB，
    // 截断时 TIFF 头（紧跟段头）仍在已取回字节内，按可用字节解析。
    if (marker == 0xe1 && length >= 8) {
      final truncated = offset + length > bytes.length;
      final segmentEnd = truncated ? bytes.length : offset + length;
      if (_isExifApp1Header(bytes, offset + 2)) {
        foundExif = true;
        final info = _parseTiffExif(bytes, offset + 8, segmentEnd);
        takenAt ??= info.takenAt;
        width ??= info.width;
        height ??= info.height;
        latitude ??= info.latitude;
        longitude ??= info.longitude;
      }
      if (truncated) break;
    } else if (offset + length > bytes.length) {
      break;
    }
    offset += length;
  }
  if (!foundExif) return null;
  return ImageExifInfo(
    takenAt: takenAt,
    latitude: latitude,
    longitude: longitude,
    width: width,
    height: height,
  );
}

bool _isExifApp1Header(List<int> bytes, int offset) =>
    offset + 6 <= bytes.length &&
    bytes[offset] == 0x45 &&
    bytes[offset + 1] == 0x78 &&
    bytes[offset + 2] == 0x69 &&
    bytes[offset + 3] == 0x66 &&
    bytes[offset + 4] == 0 &&
    bytes[offset + 5] == 0;

bool _isHeifContainer(List<int> bytes) =>
    bytes.length >= 12 &&
    bytes[4] == 0x66 && // 'ftyp'
    bytes[5] == 0x74 &&
    bytes[6] == 0x79 &&
    bytes[7] == 0x70;

/// 在 HEIF 容器头部字节中解析 EXIF。
///
/// HEIC 的 EXIF item 可能带独立 Exif 盒，也可能存放在 mdat 内由 iloc
/// 定位，头部没有固定的盒结构；直接在探测范围内搜索 TIFF 字节序头
/// （Exif 数据必以此开头）并尝试解析，解析出有效字段才采信。
ImageExifInfo? _parseHeifExif(List<int> bytes) {
  const tiffLittle = <int>[0x49, 0x49, 0x2a, 0x00];
  const tiffBig = <int>[0x4d, 0x4d, 0x00, 0x2a];
  var scanFrom = 0;
  while (scanFrom + 8 <= bytes.length) {
    var magic = _findAsciiSequence(bytes, scanFrom, tiffLittle);
    final bigMagic = _findAsciiSequence(bytes, scanFrom, tiffBig);
    if (magic < 0 || (bigMagic >= 0 && bigMagic < magic)) magic = bigMagic;
    if (magic < 0) return null;
    final info = _parseTiffExif(bytes, magic, bytes.length);
    if (info.takenAt != null ||
        info.width != null ||
        info.height != null ||
        info.latitude != null ||
        info.longitude != null) {
      return info;
    }
    scanFrom = magic + 4;
  }
  return null;
}

int _findAsciiSequence(List<int> bytes, int start, List<int> sequence) {
  if (sequence.isEmpty || bytes.length < sequence.length) return -1;
  outer:
  for (var i = start; i + sequence.length <= bytes.length; i++) {
    for (var j = 0; j < sequence.length; j++) {
      if (bytes[i + j] != sequence[j]) continue outer;
    }
    return i;
  }
  return -1;
}

bool _isJpegMetadataComplete(List<int> bytes) {
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return true;
  var offset = 2;
  while (offset + 2 <= bytes.length) {
    if (bytes[offset] != 0xff) return false;
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) return false;
    final marker = bytes[offset++];
    // SOS 之后是压缩图像数据，EXIF 不会再出现。
    if (marker == 0xda || marker == 0xd9) return true;
    if ((marker >= 0xd0 && marker <= 0xd7) || marker == 0x01) continue;
    if (offset + 2 > bytes.length) return false;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) return false;
    offset += length;
  }
  return false;
}

ImageExifInfo _parseTiffExif(List<int> bytes, int start, int end) {
  const empty = ImageExifInfo();
  if (start + 8 > end) return empty;
  final littleEndian = bytes[start] == 0x49 && bytes[start + 1] == 0x49;
  final bigEndian = bytes[start] == 0x4d && bytes[start + 1] == 0x4d;
  if (!littleEndian && !bigEndian) return empty;

  int read16(int offset) {
    if (offset + 2 > end) return -1;
    return littleEndian
        ? bytes[offset] | (bytes[offset + 1] << 8)
        : (bytes[offset] << 8) | bytes[offset + 1];
  }

  int read32(int offset) {
    if (offset + 4 > end) return -1;
    if (littleEndian) {
      return bytes[offset] |
          (bytes[offset + 1] << 8) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 24);
    }
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  String? readAscii(int entry, int count) {
    final valueOffset = count <= 4 ? entry + 8 : start + read32(entry + 8);
    if (valueOffset < start || valueOffset + count > end) return null;
    return ascii
        .decode(bytes.sublist(valueOffset, valueOffset + count),
            allowInvalid: true)
        .replaceFirst(RegExp(r'\x00.*$'), '');
  }

  /// 读取 RATIONAL（两个 32 位无符号整数之商）。
  double? readRational(int offset) {
    if (offset + 8 > end) return null;
    final numerator = read32(offset);
    final denominator = read32(offset + 4);
    if (numerator < 0 || denominator <= 0) return null;
    return numerator / denominator;
  }

  int? exifOffset;
  int? gpsOffset;
  DateTime? takenAtOriginal;
  DateTime? takenAtDigitized;
  DateTime? takenAtIfd0;
  int? width;
  int? height;
  double? latitudeValue;
  double? longitudeValue;
  var latitudeSign = 1;
  var longitudeSign = 1;
  void scanIfd(int ifdOffset, {bool exif = false, bool gps = false}) {
    final count = read16(ifdOffset);
    if (count < 0 || ifdOffset + 2 + count * 12 > end) return;
    for (var index = 0; index < count; index++) {
      final entry = ifdOffset + 2 + index * 12;
      final tag = read16(entry);
      final type = read16(entry + 2);
      final valueCount = read32(entry + 4);
      if (gps) {
        // GPS IFD：纬度/经度基准与三个 RATIONAL 分量。
        if (tag == 0x0001 && type == 2 && valueCount == 2) {
          if (readAscii(entry, 2) == 'S') latitudeSign = -1;
        }
        if (tag == 0x0003 && type == 2 && valueCount == 2) {
          if (readAscii(entry, 2) == 'W') longitudeSign = -1;
        }
        if ((tag == 0x0002 || tag == 0x0004) && type == 5 && valueCount == 3) {
          final valueOffset = start + read32(entry + 8);
          final degrees = readRational(valueOffset);
          final minutes = readRational(valueOffset + 8);
          final seconds = readRational(valueOffset + 16);
          if (degrees != null && minutes != null && seconds != null) {
            final value = degrees + minutes / 60 + seconds / 3600;
            if (tag == 0x0002) {
              latitudeValue = value;
            } else {
              longitudeValue = value;
            }
          }
        }
        continue;
      }
      if (tag == 0x8769 && type == 4 && valueCount == 1) {
        exifOffset = start + read32(entry + 8);
      }
      if (tag == 0x8825 && type == 4 && valueCount == 1) {
        gpsOffset = start + read32(entry + 8);
      }
      if (exif && tag == 0xa002 && (type == 3 || type == 4)) {
        final value = type == 3 ? read16(entry + 8) : read32(entry + 8);
        if (value > 0) width = value;
      }
      if (exif && tag == 0xa003 && (type == 3 || type == 4)) {
        final value = type == 3 ? read16(entry + 8) : read32(entry + 8);
        if (value > 0) height = value;
      }
      if (type == 2 && valueCount > 0) {
        final raw = readAscii(entry, valueCount);
        final parsed = raw == null ? null : _parseExifDate(raw);
        if (parsed == null) continue;
        // 三处时间分开记录：Exif 子 IFD 的拍摄时间优先于 IFD0 的
        // 文件时间（后者在编辑/转存后会被改写）。
        if (exif && tag == 0x9003) {
          takenAtOriginal ??= parsed;
        } else if (exif && tag == 0x9004) {
          takenAtDigitized ??= parsed;
        } else if (!exif && tag == 0x0132) {
          takenAtIfd0 ??= parsed;
        }
      }
    }
  }

  final firstIfd = start + read32(start + 4);
  scanIfd(firstIfd);
  if (exifOffset != null) scanIfd(exifOffset!, exif: true);
  if (gpsOffset != null) scanIfd(gpsOffset!, gps: true);
  final latitude = latitudeValue == null ? null : latitudeSign * latitudeValue!;
  final longitude =
      longitudeValue == null ? null : longitudeSign * longitudeValue!;
  return ImageExifInfo(
    takenAt: takenAtOriginal ?? takenAtDigitized ?? takenAtIfd0,
    latitude: (latitude != null && latitude.abs() <= 90) ? latitude : null,
    longitude: (longitude != null && longitude.abs() <= 180) ? longitude : null,
    width: width,
    height: height,
  );
}
