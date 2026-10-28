import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/transfer/presentation/transfer_format.dart';

void main() {
  group('formatTransferBytes', () {
    test('按 B/KB/MB/GB 分级', () {
      expect(formatTransferBytes(0), '0 B');
      expect(formatTransferBytes(1023), '1023 B');
      expect(formatTransferBytes(1024), '1.0 KB');
      expect(formatTransferBytes(1536), '1.5 KB');
      expect(formatTransferBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatTransferBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('负值返回占位符', () {
      expect(formatTransferBytes(-1), transferUnknownPlaceholder);
    });
  });

  group('formatTransferSpeed', () {
    test('空值与零速度返回占位符', () {
      expect(formatTransferSpeed(null), transferUnknownPlaceholder);
      expect(formatTransferSpeed(0), transferUnknownPlaceholder);
      expect(formatTransferSpeed(-1), transferUnknownPlaceholder);
    });

    test('正速度带 /s 后缀', () {
      expect(formatTransferSpeed(2 * 1024 * 1024), '2.0 MB/s');
      expect(formatTransferSpeed(512), '512 B/s');
    });
  });

  group('formatTransferDuration', () {
    test('秒/分/小时分级', () {
      expect(formatTransferDuration(null), transferUnknownPlaceholder);
      expect(formatTransferDuration(-1), transferUnknownPlaceholder);
      expect(formatTransferDuration(0), '0 秒');
      expect(formatTransferDuration(59 * 1000), '59 秒');
      expect(formatTransferDuration(60 * 1000), '1 分');
      expect(formatTransferDuration(61 * 1000), '1 分 1 秒');
      expect(formatTransferDuration(60 * 60 * 1000), '1 小时');
      expect(
        formatTransferDuration((60 * 60 + 60 * 5) * 1000),
        '1 小时 5 分',
      );
    });
  });

  group('formatTransferTimestamp', () {
    final now = DateTime(2026, 10, 28, 18, 30);

    test('缺失时间返回占位符', () {
      expect(formatTransferTimestamp(null), transferUnknownPlaceholder);
    });

    test('今天与昨天', () {
      expect(
        formatTransferTimestamp(DateTime(2026, 10, 28, 9, 5), now: now),
        '今天 09:05',
      );
      expect(
        formatTransferTimestamp(DateTime(2026, 10, 27, 23, 59), now: now),
        '昨天 23:59',
      );
    });

    test('同年展示月日，跨年展示完整年份', () {
      expect(
        formatTransferTimestamp(DateTime(2026, 10, 1, 8, 7), now: now),
        '10-01 08:07',
      );
      expect(
        formatTransferTimestamp(DateTime(2025, 12, 31, 23, 59), now: now),
        '2025-12-31 23:59',
      );
    });

    test('UTC 时间按本地时区展示', () {
      final utc = DateTime.utc(2026, 10, 28, 9, 5);
      expect(
        formatTransferTimestamp(utc, now: utc.toLocal()),
        '今天 ${_twoDigits(utc.toLocal().hour)}:05',
      );
    });
  });
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
