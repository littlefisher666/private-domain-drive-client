import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_convert/enough_convert.dart';

import '../../../core/errors/app_error.dart';
import '../../auth/domain/user_session.dart';
import '../../workspace/infrastructure/oss_client.dart';

/// 文本预览分段加载器。
///
/// 小文件（≤1MB）整段取回；大文件通过 Range 请求按 1MB 分段续载，
/// 累计上限 20MB。编码按 BOM → UTF-8 严格 → GBK → replacement 兜底
/// 确定，跨段解码时保留不完整的多字节尾部，避免字符被截断。
class TextPreviewLoader {
  TextPreviewLoader({
    required OssClient ossClient,
    required UserSession session,
    required String path,
    int? fileSize,
  })  : _ossClient = ossClient,
        _session = session,
        _path = path,
        _fileSize = fileSize;

  static const int segmentBytes = 1024 * 1024;
  static const int maxLoadedBytes = 20 * 1024 * 1024;

  final OssClient _ossClient;
  final UserSession _session;
  final String _path;
  final int? _fileSize;

  final BytesBuilder _pendingTail = BytesBuilder(copy: false);
  String Function(List<int> bytes)? _decodeSegment;
  bool _gbkMode = false;
  int _skipBytes = 0;
  int _fetchedBytes = 0;
  bool _complete = false;
  bool _reachedLimit = false;
  bool _encodingUnknown = false;

  /// 文件是否已全部加载（小文件整段或大文件读到 EOF）。
  bool get complete => _complete;

  /// 是否已达到 20MB 累计上限，停止继续加载。
  bool get reachedLimit => _reachedLimit;

  /// 编码无法识别（已按 replacement 字符展示）。
  bool get encodingUnknown => _encodingUnknown;

  /// 已加载的字节数。
  int get loadedBytes => _fetchedBytes;

  /// 加载下一分段并返回新追加的解码文本；返回空字符串表示没有更多
  /// 内容。首次调用加载首段。失败时抛出异常，可再次调用重试。
  Future<String> loadMore() async {
    if (_complete || _reachedLimit) return '';
    List<int> chunk;
    try {
      chunk = await _fetchNextChunk();
    } on AppError {
      // 已读到内容时再失败，大概率是文件末尾的越界 Range 请求
      // （分片恰好对齐 EOF），按读满处理；首段失败照常抛出。
      if (_fetchedBytes > 0) {
        _complete = true;
        return '';
      }
      rethrow;
    }
    if (chunk.isEmpty) {
      _complete = true;
      return '';
    }
    _fetchedBytes += chunk.length;
    if (_fileSize == null && chunk.length < segmentBytes) {
      _complete = true;
    }
    if (_fileSize != null && _fetchedBytes >= _fileSize) {
      _complete = true;
    }
    if (_fetchedBytes >= maxLoadedBytes && !_complete) {
      _reachedLimit = true;
    }

    final decode = _decodeSegment ??= _createDecoder(chunk);
    final tail = _pendingTail.takeBytes();
    final buffer = <int>[...tail, ...chunk];
    if (!_complete && !_reachedLimit) {
      final carry = _trailingIncompleteBytes(buffer);
      if (carry > 0) {
        _pendingTail.add(buffer.sublist(buffer.length - carry));
        return _decodeSafe(
            decode, buffer.sublist(0, buffer.length - carry));
      }
      return _decodeSafe(decode, buffer);
    }
    return _decodeSafe(decode, buffer);
  }

  String _decodeSafe(String Function(List<int> bytes) decode, List<int> bytes) {
    if (_skipBytes > 0) {
      if (_skipBytes >= bytes.length) {
        _skipBytes -= bytes.length;
        return '';
      }
      bytes = bytes.sublist(_skipBytes);
      _skipBytes = 0;
    }
    return decode(bytes);
  }

  Future<List<int>> _fetchNextChunk() async {
    if (_fileSize != null &&
        _fileSize <= segmentBytes &&
        _fileSize > 0 &&
        _fetchedBytes == 0) {
      // 小文件整段取回，与图片链路一致。
      return _ossClient.download(_path, _session, maxBytes: segmentBytes);
    }
    final start = _fetchedBytes;
    final end = start + segmentBytes - 1;
    return _ossClient.getObjectRange(
      _path,
      _session,
      startByte: start,
      endByte: end,
    );
  }

  /// 依据首段数据确定解码函数（BOM → UTF-8 严格 → GBK → replacement）。
  /// 带 BOM 的 UTF-8 通过跳过前缀字节处理。
  String Function(List<int> bytes) _createDecoder(List<int> firstChunk) {
    // UTF-8 BOM。
    if (firstChunk.length >= 3 &&
        firstChunk[0] == 0xef &&
        firstChunk[1] == 0xbb &&
        firstChunk[2] == 0xbf) {
      _skipBytes = 3;
      return _utf8Decoder();
    }

    // 无 BOM：先剥离尾部不完整序列再严格探测。UTF-8 通过则按 UTF-8；
    // 失败回退 GBK；GBK 也失败按 UTF-8 replacement 展示并提示未知编码。
    final probe = firstChunk.sublist(
      0,
      firstChunk.length - _utf8TrailingIncomplete(firstChunk),
    );
    try {
      utf8.decode(probe, allowMalformed: false);
      return _utf8Decoder();
    } on FormatException {
      final gbkProbe = firstChunk.sublist(
        0,
        firstChunk.length - _gbkTrailingIncomplete(firstChunk),
      );
      try {
        const GbkDecoder(allowInvalid: false).convert(gbkProbe);
        _gbkMode = true;
        return _gbkDecoder();
      } catch (_) {
        _encodingUnknown = true;
        return _utf8ReplacementDecoder();
      }
    }
  }

  String Function(List<int> bytes) _utf8Decoder() {
    return (bytes) {
      try {
        return utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        // 首段探测通过但后续内容确有非法字节，降级为 replacement 展示。
        return utf8.decode(bytes, allowMalformed: true);
      }
    };
  }

  String Function(List<int> bytes) _gbkDecoder() {
    return (bytes) {
      try {
        return const GbkDecoder(allowInvalid: false).convert(bytes);
      } on FormatException {
        return const GbkDecoder(allowInvalid: true).convert(bytes);
      }
    };
  }

  String Function(List<int> bytes) _utf8ReplacementDecoder() {
    return (bytes) => utf8.decode(bytes, allowMalformed: true);
  }

  /// 当前编码下缓冲区尾部无法确定完整的多字节序列长度。
  int _trailingIncompleteBytes(List<int> bytes) => _gbkMode
      ? _gbkTrailingIncomplete(bytes)
      : _utf8TrailingIncomplete(bytes);

  /// UTF-8 缓冲区尾部不完整序列长度（最多 3 字节；完整或纯 ASCII 为 0）。
  static int _utf8TrailingIncomplete(List<int> bytes) {
    var count = 0;
    while (count < bytes.length && count < 3) {
      final byte = bytes[bytes.length - 1 - count];
      if (byte & 0xc0 != 0x80) {
        // 找到起始字节：检查该序列是否完整。
        final expected = _utf8SequenceLength(byte);
        return expected > count + 1 ? count + 1 : 0;
      }
      count++;
    }
    return count;
  }

  static int _utf8SequenceLength(int leadByte) {
    if (leadByte & 0x80 == 0) return 1;
    if (leadByte & 0xe0 == 0xc0) return 2;
    if (leadByte & 0xf0 == 0xe0) return 3;
    return 4;
  }

  /// GBK 缓冲区尾部不完整双字节序列长度（最多 1 字节）。
  static int _gbkTrailingIncomplete(List<int> bytes) {
    if (bytes.isEmpty) return 0;
    final last = bytes.last;
    return last >= 0x81 && last <= 0xfe ? 1 : 0;
  }
}
