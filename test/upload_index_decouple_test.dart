import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/transfer/domain/transfer_task.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/shared/gallery_index_hooks.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSessionRepository implements SessionRepository {
  _FakeSessionRepository(this.session);

  final UserSession? session;

  @override
  Future<UserSession?> restore() async => session;

  @override
  Future<UserSession> login({
    required String account,
    required String password,
  }) async =>
      session!;

  @override
  Future<UserSession> changePassword({
    required UserSession session,
    required String currentPassword,
    required String newPassword,
  }) async =>
      session;

  @override
  Future<void> logout() async {}
}

class _FastOss extends OssClient {
  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<bool> objectExists(String path, UserSession session) async => false;

  @override
  Future<void> uploadFile(
    String path,
    String localPath,
    UserSession session, {
    required String taskId,
    void Function(int transferredBytes, int totalBytes)? onProgress,
  }) async {
    onProgress?.call(1, 1);
  }
}

/// 可控的索引挂钩：onMediaUploaded 被 gate 挂起，模拟耗时的索引簿记。
class _GatedHooks implements GalleryIndexHooks {
  final Completer<void> gate = Completer<void>();
  bool hookStarted = false;
  bool hookCompleted = false;

  @override
  Future<String?> prepareVideoThumbnail(
    String objectPath,
    String localPath,
  ) async =>
      null;

  @override
  Future<String?> prepareImageThumbnail(
    String objectPath,
    String localPath,
  ) async =>
      null;

  @override
  Future<void> onMediaUploaded({
    required String objectPath,
    required String localPath,
    String? thumbLocalPath,
  }) async {
    hookStarted = true;
    await gate.future;
    hookCompleted = true;
  }

  @override
  Future<void> onObjectsDeleted(Set<String> objectKeys) async {}

  @override
  Future<void> onObjectsRestored(Set<String> objectKeys) async {}
}

UserSession _remoteSession() {
  return const UserSession(
    userId: 'tester',
    account: 'tester',
    displayName: 'tester',
    role: 'member',
    capabilities: Capabilities.member(),
    rootPrefix: 'shared/',
    ossConfig: OssConfig(
      bucket: 'bucket',
      region: 'cn-test',
      endpoint: 'oss-cn-test.aliyuncs.com',
      rootPrefix: 'shared/',
    ),
    credentials: OssCredentials(accessKeyId: 'ak', accessKeySecret: 'sk'),
  );
}

Future<void> _waitFor(
  Future<bool> Function() predicate, {
  String? because,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('等待条件超时${because == null ? '' : '：$because'}');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    for (final dir in Directory.systemTemp.listSync().whereType<Directory>()) {
      if (dir.path.contains('pdd-cache-') || dir.path.contains('pdd-support-')) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  });

  test('上传任务在 OSS 成功后立即标记成功，索引簿记不阻塞并发槽', () async {
    final hooks = _GatedHooks();
    final controller = AppController(
      sessionRepository: _FakeSessionRepository(_remoteSession()),
      ossClient: _FastOss(),
    );
    addTearDown(controller.dispose);
    controller.setGalleryHooks(hooks);
    await controller.bootstrap();

    final source = File(
      '${Directory.systemTemp.path}'
      '/index-decouple-${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await source.writeAsString('payload');
    addTearDown(() {
      try {
        source.deleteSync();
      } catch (_) {}
    });

    await controller.uploadFile(
      fileName: 'photo.jpg',
      localPath: source.path,
      fileSize: 7,
    );

    // 索引簿记仍被 gate 挂起时，传输任务应已成功（并发槽已释放）。
    await _waitFor(
      () async => controller.tasks.first.status == TransferTaskStatus.success,
      because: 'OSS 成功后任务应立即标记成功，不等索引钩子',
    );
    expect(hooks.hookStarted, isTrue);
    expect(hooks.hookCompleted, isFalse);

    hooks.gate.complete();
    await _waitFor(
      () async => hooks.hookCompleted,
      because: '索引钩子应在后台继续执行完成',
    );
    expect(controller.tasks.first.status, TransferTaskStatus.success);
  });

  test('索引钩子抛出异常不影响任务成功状态', () async {
    final hooks = _ThrowingHooks();
    final controller = AppController(
      sessionRepository: _FakeSessionRepository(_remoteSession()),
      ossClient: _FastOss(),
    );
    addTearDown(controller.dispose);
    controller.setGalleryHooks(hooks);
    await controller.bootstrap();

    final source = File(
      '${Directory.systemTemp.path}'
      '/index-decouple-err-${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await source.writeAsString('payload');
    addTearDown(() {
      try {
        source.deleteSync();
      } catch (_) {}
    });

    await controller.uploadFile(
      fileName: 'photo.jpg',
      localPath: source.path,
      fileSize: 7,
    );

    await _waitFor(
      () async => hooks.hookCompleted,
      because: '后台钩子应执行完毕',
    );
    expect(controller.tasks.first.status, TransferTaskStatus.success);
  });
}

class _ThrowingHooks implements GalleryIndexHooks {
  bool hookCompleted = false;

  @override
  Future<String?> prepareVideoThumbnail(
    String objectPath,
    String localPath,
  ) async =>
      null;

  @override
  Future<String?> prepareImageThumbnail(
    String objectPath,
    String localPath,
  ) async =>
      null;

  @override
  Future<void> onMediaUploaded({
    required String objectPath,
    required String localPath,
    String? thumbLocalPath,
  }) async {
    hookCompleted = true;
    throw StateError('索引簿记失败');
  }

  @override
  Future<void> onObjectsDeleted(Set<String> objectKeys) async {}

  @override
  Future<void> onObjectsRestored(Set<String> objectKeys) async {}
}
