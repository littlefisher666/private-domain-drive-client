import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/directory_summary_service.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_oss/private_domain_oss.dart';

void main() {
  test('refresh 受并发上限约束并逐个回调全部结果', () async {
    final native = _GatingNative();
    final service = _service(native);
    final paths = <String>[
      for (var index = 0; index < 8; index++) 'shared/dir$index/',
    ];
    final results = <String>[];

    await service.refresh(paths, (path, summary) {
      results.add(path);
      expect(summary.itemCount, 0);
    });

    expect(results.length, paths.length);
    expect(native.maxInFlight, lessThanOrEqualTo(4));
    expect(native.maxInFlight, greaterThanOrEqualTo(2));
  });

  test('generation 递增后丢弃过期目录的统计回调', () async {
    final native = _GatingNative();
    final service = _service(native);
    final paths = <String>['shared/a/', 'shared/b/'];
    final results = <String>[];

    final future = service.refresh(paths, (path, summary) {
      results.add(path);
    });
    // 等待两个统计请求在途后模拟目录切换，再放行结果。
    native.holdRequests = true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    service.bumpGeneration();
    native.releaseAll();
    await future;

    expect(results, isEmpty);
  });

  test('无会话时统计与缓存读取全部降级为空', () async {
    final native = _GatingNative();
    final service = DirectorySummaryService(
      ossClient: OssClient(native: native),
      sessionProvider: () => null,
    );

    expect(await service.cached('shared/a/'), isNull);
    expect(await service.cachedAll(<String>['shared/a/']), isEmpty);
    await service.refresh(<String>['shared/a/'], (_, __) {
      fail('无会话时不应发起统计');
    });
    expect(native.listCalls, 0);
  });
}

DirectorySummaryService _service(_GatingNative native) {
  return DirectorySummaryService(
    ossClient: OssClient(native: native),
    sessionProvider: _session,
  );
}

UserSession _session() {
  return const UserSession(
    userId: 'u1',
    account: 'u1',
    displayName: '测试用户',
    role: 'member',
    capabilities: Capabilities.member(),
    rootPrefix: 'shared/',
    ossConfig: OssConfig(
      bucket: 'bucket',
      region: 'cn-hangzhou',
      endpoint: 'https://oss-cn-hangzhou.aliyuncs.com',
      rootPrefix: 'shared/',
    ),
    credentials: OssCredentials(
      accessKeyId: 'id',
      accessKeySecret: 'secret',
    ),
  );
}

/// 可用 Completer 阻塞列举请求的原生 facade，用于验证并发上限与
/// generation 丢弃逻辑。统计缓存层在测试环境自动降级为空操作。
class _GatingNative extends PrivateDomainOss {
  _GatingNative() : super(methodChannel: const MethodChannel('test/unused'));

  final Map<String, Completer<void>> _gates =
      <String, Completer<void>>{};
  var inFlight = 0;
  var maxInFlight = 0;
  var listCalls = 0;

  /// 置为 true 时列举请求阻塞直到 [releaseAll]，用于固定在途窗口。
  var holdRequests = false;

  void releaseAll() {
    for (final gate in _gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  Future<void> configure({
    required String endpoint,
    required String region,
    required String bucket,
    required String accessKeyId,
    required String accessKeySecret,
  }) async {}

  @override
  Future<OssListPage> listObjects({
    required String prefix,
    String? delimiter,
    String? marker,
    int maxKeys = 1000,
  }) async {
    listCalls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    final gate = _gates.putIfAbsent(prefix, Completer.new);
    if (holdRequests && !gate.isCompleted) {
      await gate.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    } else {
      await Future<void>.delayed(Duration.zero);
    }
    inFlight--;
    return const OssListPage(
      objects: <OssNativeObject>[],
      commonPrefixes: <String>[],
      isTruncated: false,
    );
  }
}
