import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/workspace/domain/recycle_bin_entry.dart';

void main() {
  test('回收站 manifest 可往返编码，并按删除时间计算 30 天到期日', () {
    final entry = RecycleBinEntry(
      id: 'batch-1',
      name: '资料',
      originalPath: 'shared/资料/',
      isDirectory: true,
      deletedAt: DateTime(2026, 9, 20),
      objects: const <String, String>{
        'shared/资料/a.txt': 'shared/.trash/batch-1/payload/资料/a.txt',
      },
    );

    final decoded = RecycleBinEntry.decode(entry.encode());

    expect(decoded.id, 'batch-1');
    expect(decoded.objects.keys, contains('shared/资料/a.txt'));
    expect(decoded.expiresAt, DateTime(2026, 10, 20));
  });
}
