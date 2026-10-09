enum PreviewType {
  image,
  pdf,
  markdown,
  csv,
  text,
  audio,
  unsupported,
}

extension PreviewTypeResolver on PreviewType {
  /// Markdown 与 CSV 归入专用渲染类型，其余代码/配置/日志类扩展名
  /// 全部进入纯文本预览链路。
  static const _textExtensions = <String>[
    '.txt',
    '.json',
    '.log',
    '.dart',
    '.py',
    '.js',
    '.mjs',
    '.cjs',
    '.ts',
    '.tsx',
    '.jsx',
    '.java',
    '.kt',
    '.go',
    '.rs',
    '.c',
    '.h',
    '.cpp',
    '.cs',
    '.rb',
    '.php',
    '.swift',
    '.yaml',
    '.yml',
    '.xml',
    '.html',
    '.htm',
    '.css',
    '.scss',
    '.ini',
    '.conf',
    '.cfg',
    '.properties',
    '.toml',
    '.env',
    '.sh',
    '.bash',
    '.zsh',
    '.bat',
    '.ps1',
    '.sql',
    '.dockerfile',
    '.gitignore',
    '.gitattributes',
  ];

  static const _audioExtensions = <String>[
    '.mp3',
    '.m4a',
    '.flac',
    '.wav',
    '.aac',
    '.ogg',
    '.opus',
    '.wma',
  ];

  static bool _hasExtension(String normalized, Iterable<String> extensions) =>
      extensions.any(normalized.endsWith);

  static PreviewType fromFileName(String fileName) {
    final normalized = fileName.toLowerCase();

    if (normalized.endsWith('.png') ||
        normalized.endsWith('.jpg') ||
        normalized.endsWith('.jpeg') ||
        normalized.endsWith('.webp')) {
      return PreviewType.image;
    }

    if (normalized.endsWith('.pdf')) {
      return PreviewType.pdf;
    }

    if (normalized.endsWith('.md') || normalized.endsWith('.markdown')) {
      return PreviewType.markdown;
    }

    if (normalized.endsWith('.csv') || normalized.endsWith('.tsv')) {
      return PreviewType.csv;
    }

    if (_hasExtension(normalized, _textExtensions)) {
      return PreviewType.text;
    }

    if (_hasExtension(normalized, _audioExtensions)) {
      return PreviewType.audio;
    }

    // 无扩展名但名称形如 Dockerfile 的常见文本文件。
    if (normalized == 'dockerfile' || normalized == 'makefile') {
      return PreviewType.text;
    }

    return PreviewType.unsupported;
  }
}
