enum PreviewType {
  image,
  pdf,
  text,
  unsupported,
}

extension PreviewTypeResolver on PreviewType {
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

    if (normalized.endsWith('.txt') ||
        normalized.endsWith('.md') ||
        normalized.endsWith('.json') ||
        normalized.endsWith('.yaml') ||
        normalized.endsWith('.yml')) {
      return PreviewType.text;
    }

    return PreviewType.unsupported;
  }
}
