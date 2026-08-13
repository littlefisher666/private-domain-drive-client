import 'package:flutter/material.dart';

import '../../app/theme/cupertino_desktop.dart';
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
      FileKind.file => (Icons.insert_drive_file_outlined, scheme.onSurfaceVariant),
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
