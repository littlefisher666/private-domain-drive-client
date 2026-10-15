import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 传输保活平台适配层：存在活跃传输任务时在 Android 上以前台服务保活
/// 进程并挂常驻进度通知。`AppController` 只感知该抽象接口，
/// `Platform.isAndroid` 判断收敛在本文件内，其余平台为 no-op。
abstract class TransferKeepaliveService {
  const TransferKeepaliveService();

  /// 幂等推送传输队列活跃状态与进度摘要：
  /// 空闲转活跃时启动前台服务、活跃期间节流更新通知、
  /// 活跃转空闲时立即停止服务。活跃状态切换不节流。
  Future<void> sync({required bool active, TransferProgressSummary? summary});

  /// Android 13+ 首次发起传输前请求通知权限；每个应用会话内仅请求一次。
  /// 拒绝授权不影响传输与前台服务，仅通知不展示。
  Future<void> requestNotificationPermissionIfNeeded();
}

/// 传输队列进度摘要：剩余任务数（进行中 + 等待中）、当前批次已完成/
/// 总任务数与按文件数计的本批次完成百分比。
class TransferProgressSummary {
  const TransferProgressSummary({
    required this.remainingCount,
    required this.completedCount,
    required this.totalCount,
    required this.percent,
  });

  final int remainingCount;
  final int completedCount;
  final int totalCount;
  final int percent;

  @override
  bool operator ==(Object other) =>
      other is TransferProgressSummary &&
      other.remainingCount == remainingCount &&
      other.completedCount == completedCount &&
      other.totalCount == totalCount &&
      other.percent == percent;

  @override
  int get hashCode => Object.hash(remainingCount, completedCount, totalCount, percent);
}

/// 非 Android 平台的空实现，macOS 传输行为不受任何影响。
class NoopTransferKeepaliveService extends TransferKeepaliveService {
  const NoopTransferKeepaliveService();

  @override
  Future<void> sync({required bool active, TransferProgressSummary? summary}) async {}

  @override
  Future<void> requestNotificationPermissionIfNeeded() async {}
}

/// 平台分支工厂：Android 走 MethodChannel 前台服务实现，其余平台 no-op。
TransferKeepaliveService createTransferKeepaliveService({bool? isAndroid}) {
  final android = isAndroid ?? Platform.isAndroid;
  return android
      ? AndroidTransferKeepaliveService()
      : const NoopTransferKeepaliveService();
}

/// 进度通知节流：内容变化且距上次更新不短于 [minInterval] 才允许更新。
/// 时钟可注入，便于用假时钟做单测。
class TransferNotificationThrottle {
  TransferNotificationThrottle({
    this.minInterval = const Duration(seconds: 1),
    Duration Function()? clock,
  }) : _clock = clock ?? _defaultClock {
    _origin = _clock();
  }

  static Duration _defaultClock() => DateTime.now().difference(_epoch);

  static final DateTime _epoch = DateTime.now();

  final Duration minInterval;
  final Duration Function() _clock;
  late Duration _origin;
  Duration? _lastUpdateAt;
  String? _lastKey;

  /// 内容未变化或处于节流窗口内时返回 false，否则记录并放行。
  bool shouldUpdate(String key) {
    if (key == _lastKey) return false;
    final elapsed = _clock() - _origin;
    final last = _lastUpdateAt;
    if (last != null && elapsed - last < minInterval) return false;
    _lastUpdateAt = elapsed;
    _lastKey = key;
    return true;
  }

  /// 服务启动/停止时重置：下次活跃首次推送不节流。
  void reset() {
    _lastUpdateAt = null;
    _lastKey = null;
  }
}

class AndroidTransferKeepaliveService extends TransferKeepaliveService {
  AndroidTransferKeepaliveService();

  static const _channel =
      MethodChannel('private_domain_drive/transfer_keepalive');

  bool _permissionRequested = false;
  bool _serviceRunning = false;
  final TransferNotificationThrottle _throttle = TransferNotificationThrottle();

  @override
  Future<void> sync({required bool active, TransferProgressSummary? summary}) async {
    try {
      if (active) {
        final payload = <String, Object?>{
          'completed': summary?.completedCount ?? 0,
          'total': summary?.totalCount ?? 0,
          'percent': summary?.percent ?? 0,
        };
        if (!_serviceRunning) {
          await _channel.invokeMethod<void>('start', payload);
          _serviceRunning = true;
          _throttle.reset();
        } else if (summary != null &&
            _throttle.shouldUpdate(
                '${summary.completedCount}/${summary.totalCount}:${summary.percent}')) {
          await _channel.invokeMethod<void>('update', payload);
        }
      } else if (_serviceRunning) {
        // 队列由活跃转空闲：先停止服务移除常驻通知，原生端随后以完成
        // 渠道弹出「传输完成」悬浮横幅。
        await _channel.invokeMethod<void>('stop', <String, Object?>{
          'completed': true,
        });
        _serviceRunning = false;
        _throttle.reset();
      }
    } on PlatformException catch (error) {
      debugPrint('[传输保活] 前台服务操作失败：${error.code} ${error.message}');
    } on MissingPluginException {
      debugPrint('[传输保活] 原生端未实现 transfer_keepalive 通道');
    }
  }

  @override
  Future<void> requestNotificationPermissionIfNeeded() async {
    if (_permissionRequested) return;
    _permissionRequested = true;
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } on PlatformException catch (error) {
      debugPrint('[传输保活] 通知权限请求失败：${error.code} ${error.message}');
    } on MissingPluginException {
      debugPrint('[传输保活] 原生端未实现 transfer_keepalive 通道');
    }
  }
}
