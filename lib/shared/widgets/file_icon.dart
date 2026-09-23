import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/cupertino_desktop.dart';
import '../../core/errors/app_error.dart';
import '../../features/workspace/domain/file_item.dart';

class FileTypeIcon extends StatelessWidget {
  const FileTypeIcon({
    super.key,
    required this.item,
    this.size = 28,
  });

  final FileItem item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (item.kind) {
      FileKind.folder => (Icons.folder_rounded, scheme.primary),
      FileKind.image => (Icons.image_outlined, const Color(0xFF0F766E)),
      FileKind.pdf => (Icons.picture_as_pdf_outlined, const Color(0xFFDC2626)),
      FileKind.text => (Icons.description_outlined, const Color(0xFF2563EB)),
      FileKind.file => (
          Icons.insert_drive_file_outlined,
          scheme.onSurfaceVariant
        ),
    };

    return Icon(icon, size: size, color: color);
  }
}

class FileTypeBadge extends StatelessWidget {
  const FileTypeBadge({
    super.key,
    required this.item,
    this.size = 34,
  });

  final FileItem item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final style = _styleFor(item.kind);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        style.label,
        style: TextStyle(
          color: style.fg,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class FileTypeThumb extends StatelessWidget {
  const FileTypeThumb({
    super.key,
    required this.item,
    this.height = 84,
  });

  final FileItem item;
  final double height;

  @override
  Widget build(BuildContext context) {
    final style = _styleFor(item.kind);
    final isImage = item.kind == FileKind.image;
    return Container(
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(isImage ? 18 : 12),
        gradient: isImage
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[Color(0xFFB2F0D6), Color(0xFF9AD7FF)],
              )
            : null,
        color: isImage ? null : style.bg,
      ),
      child: Text(
        style.label,
        style: TextStyle(
          color: isImage ? const Color(0xFF0B3B2E) : style.fg,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class FileTypeThumbnail extends StatefulWidget {
  const FileTypeThumbnail({
    super.key,
    required this.item,
    required this.loader,
    this.height = 84,
    this.cacheNamespace = '',
  });

  final FileItem item;
  final Future<List<int>> Function(FileItem item) loader;
  final double height;
  final String cacheNamespace;

  @override
  State<FileTypeThumbnail> createState() => _FileTypeThumbnailState();
}

class _FileTypeThumbnailState extends State<FileTypeThumbnail> {
  static const _maxConcurrentRequests = 6;
  static final Map<String, Future<List<int>>> _inFlight =
      <String, Future<List<int>>>{};
  static final Set<String> _reportedFailures = <String>{};
  static final Queue<Completer<void>> _requestQueue = Queue<Completer<void>>();
  static var _activeRequests = 0;

  late String _cacheKey;
  Future<List<int>>? _thumbnailFuture;
  MemoryImage? _imageProvider;
  String? _imageProviderKey;

  @override
  void initState() {
    super.initState();
    _cacheKey = _keyFor(widget.item, widget.cacheNamespace);
  }

  @override
  void didUpdateWidget(covariant FileTypeThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextKey = _keyFor(widget.item, widget.cacheNamespace);
    if (nextKey != _cacheKey || oldWidget.item.kind != widget.item.kind) {
      _cacheKey = nextKey;
      _thumbnailFuture = null;
      _imageProvider = null;
      _imageProviderKey = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = _fallback(context);
    if (widget.item.kind != FileKind.image) {
      return fallback;
    }

    final key = _cacheKey;
    final future = _thumbnailFuture ??= _futureForCurrentItem();

    final content = FutureBuilder<List<int>>(
      future: future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (snapshot.connectionState == ConnectionState.done &&
            bytes != null &&
            bytes.isNotEmpty) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image(
              image: _imageProviderFor(key, bytes),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => fallback,
            ),
          );
        }
        return fallback;
      },
    );
    return widget.height == double.infinity
        ? SizedBox.expand(child: content)
        : SizedBox(height: widget.height, child: content);
  }

  Future<List<int>> _futureForCurrentItem() {
    return _inFlight.putIfAbsent(
      _cacheKey,
      () => _load(_cacheKey, widget.item, widget.loader),
    );
  }

  MemoryImage _imageProviderFor(String key, List<int> bytes) {
    if (_imageProvider == null || _imageProviderKey != key) {
      _imageProvider = MemoryImage(Uint8List.fromList(bytes));
      _imageProviderKey = key;
    }
    return _imageProvider!;
  }

  Widget _fallback(BuildContext context) {
    final style = _styleFor(widget.item.kind);
    final container = Container(
      height: widget.height == double.infinity ? null : widget.height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: style.bg,
      ),
      child: FileTypeIcon(item: widget.item, size: 36),
    );
    return widget.height == double.infinity
        ? SizedBox.expand(child: container)
        : container;
  }

  static String _keyFor(FileItem item, String namespace) {
    return '$namespace|${item.path}|${item.objectVersionToken}|'
        '${ImageThumbnailSpec.process()}';
  }

  Future<List<int>> _load(
    String key,
    FileItem item,
    Future<List<int>> Function(FileItem item) loader,
  ) {
    return _withRequestPermit(() async {
      try {
        return await loader(item);
      } catch (error) {
        final code = error is AppError ? error.code : error.runtimeType;
        final failureKey = '$key|$code';
        if (kDebugMode && _reportedFailures.add(failureKey)) {
          if (_reportedFailures.length > 100) {
            _reportedFailures.remove(_reportedFailures.first);
          }
          debugPrint('缩略图加载失败：${item.path}（$code）');
        }
        rethrow;
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  static Future<T> _withRequestPermit<T>(Future<T> Function() action) async {
    if (_activeRequests >= _maxConcurrentRequests) {
      final waiter = Completer<void>();
      _requestQueue.add(waiter);
      await waiter.future;
    }
    _activeRequests++;
    try {
      return await action();
    } finally {
      _activeRequests--;
      if (_requestQueue.isNotEmpty) {
        _requestQueue.removeFirst().complete();
      }
    }
  }
}

class _FileStyle {
  const _FileStyle({
    required this.bg,
    required this.fg,
    required this.label,
  });

  final Color bg;
  final Color fg;
  final String label;
}

_FileStyle _styleFor(FileKind kind) {
  return switch (kind) {
    FileKind.folder => const _FileStyle(
        bg: CupertinoDesktopTokens.folderBg,
        fg: CupertinoDesktopTokens.folderFg,
        label: 'DIR',
      ),
    FileKind.image => const _FileStyle(
        bg: CupertinoDesktopTokens.imageBg,
        fg: CupertinoDesktopTokens.imageFg,
        label: 'IMG',
      ),
    FileKind.pdf => const _FileStyle(
        bg: CupertinoDesktopTokens.pdfBg,
        fg: CupertinoDesktopTokens.pdfFg,
        label: 'PDF',
      ),
    FileKind.text => const _FileStyle(
        bg: CupertinoDesktopTokens.textBg,
        fg: CupertinoDesktopTokens.textFg,
        label: 'TXT',
      ),
    FileKind.file => const _FileStyle(
        bg: CupertinoDesktopTokens.fileBg,
        fg: CupertinoDesktopTokens.fileFg,
        label: 'FILE',
      ),
  };
}
