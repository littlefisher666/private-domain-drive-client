import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/core/utils/file_size_formatter.dart';

void main() {
  group('FileSizeFormatter', () {
    test('会根据文件大小自动切换单位', () {
      expect(FileSizeFormatter.format(1023), '1023 B');
      expect(FileSizeFormatter.format(1024), '1.0 KB');
      expect(FileSizeFormatter.format(1024 * 1024), '1.0 MB');
      expect(FileSizeFormatter.format(1024 * 1024 * 1024), '1.0 GB');
      expect(
        FileSizeFormatter.format(1024 * 1024 * 1024 * 1024),
        '1.0 TB',
      );
    });
  });
}
