import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/shared/transfer_keepalive.dart';

void main() {
  group('TransferNotificationThrottle', () {
    test('首次推送不节流', () {
      var now = Duration.zero;
      final throttle = TransferNotificationThrottle(clock: () => now);

      expect(throttle.shouldUpdate('2:0'), isTrue);
    });

    test('节流窗口内的进度更新被丢弃', () {
      var now = Duration.zero;
      final throttle = TransferNotificationThrottle(clock: () => now);

      expect(throttle.shouldUpdate('1:0'), isTrue);
      now = const Duration(milliseconds: 500);
      expect(throttle.shouldUpdate('1:30'), isFalse);
      now = const Duration(milliseconds: 999);
      expect(throttle.shouldUpdate('1:45'), isFalse);
    });

    test('超过最短间隔且内容变化时放行', () {
      var now = Duration.zero;
      final throttle = TransferNotificationThrottle(clock: () => now);

      expect(throttle.shouldUpdate('1:0'), isTrue);
      now = const Duration(seconds: 1);
      expect(throttle.shouldUpdate('1:60'), isTrue);
    });

    test('内容未变化时不更新', () {
      var now = Duration.zero;
      final throttle = TransferNotificationThrottle(clock: () => now);

      expect(throttle.shouldUpdate('5:45'), isTrue);
      now = const Duration(seconds: 5);
      expect(throttle.shouldUpdate('5:45'), isFalse);
    });

    test('reset 后首次推送不节流', () {
      var now = Duration.zero;
      final throttle = TransferNotificationThrottle(clock: () => now);

      expect(throttle.shouldUpdate('1:0'), isTrue);
      throttle.reset();
      expect(throttle.shouldUpdate('1:10'), isTrue);
    });
  });

  group('createTransferKeepaliveService', () {
    test('非 Android 平台返回 no-op 实现', () {
      final service = createTransferKeepaliveService(isAndroid: false);
      expect(service, isA<NoopTransferKeepaliveService>());
    });

    test('Android 平台返回前台服务实现', () {
      final service = createTransferKeepaliveService(isAndroid: true);
      expect(service, isA<AndroidTransferKeepaliveService>());
    });
  });

  group('NoopTransferKeepaliveService', () {
    test('sync 与权限请求均可安全空转', () async {
      const service = NoopTransferKeepaliveService();

      await service.sync(
        active: true,
        summary: const TransferProgressSummary(
            remainingCount: 1, completedCount: 0, totalCount: 1, percent: 0),
      );
      await service.sync(active: false);
      await service.requestNotificationPermissionIfNeeded();
    });
  });
}
