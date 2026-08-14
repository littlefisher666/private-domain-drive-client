import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/preview/domain/preview_type.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';

void main() {
  test('文件类型识别覆盖图片、PDF、文本与未知文件', () {
    expect(
      const FileItem(path: 'shared/a.JPG', name: 'a.JPG', isDirectory: false)
          .kind,
      FileKind.image,
    );
    expect(
      const FileItem(path: 'shared/a.pdf', name: 'a.pdf', isDirectory: false)
          .kind,
      FileKind.pdf,
    );
    expect(
      const FileItem(path: 'shared/a.csv', name: 'a.csv', isDirectory: false)
          .kind,
      FileKind.text,
    );
    expect(
      const FileItem(path: 'shared/a.zip', name: 'a.zip', isDirectory: false)
          .kind,
      FileKind.file,
    );
  });

  test('预览类型识别覆盖图片、PDF、文本与不支持文件', () {
    expect(PreviewTypeResolver.fromFileName('封面.PNG'), PreviewType.image);
    expect(PreviewTypeResolver.fromFileName('说明.pdf'), PreviewType.pdf);
    expect(PreviewTypeResolver.fromFileName('说明.md'), PreviewType.text);
    expect(
        PreviewTypeResolver.fromFileName('压缩包.zip'), PreviewType.unsupported);
  });
}
