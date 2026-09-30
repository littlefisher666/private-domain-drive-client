import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';

/// 回归：拍摄时间必须取 Exif 子 IFD 的 DateTimeOriginal，
/// 而非 IFD0 的 DateTime（后者在编辑/转存后会被改写为保存时间）。
/// 测试件由 PIL 生成：IFD0.DateTime=2024-05-01，
/// DateTimeOriginal=2023-12-25 08:30:00，GPS 34°12'N 108°51'E。
void main() {
  test('优先取 DateTimeOriginal 而非 IFD0 DateTime', () async {
    final info = await OssClient()
        .readLocalImageExif(File('test/fixtures/exif_datetime_original.jpg'));

    expect(info.takenAt, DateTime(2023, 12, 25, 8, 30));
    expect(info.latitude, closeTo(34.2, 0.001));
    expect(info.longitude, closeTo(108.85, 0.001));
  });
}
