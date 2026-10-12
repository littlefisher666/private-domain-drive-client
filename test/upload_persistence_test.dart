import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/transfer/domain/transfer_task.dart';
import 'package:private_domain_drive_client/features/transfer/infrastructure/upload_staging.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';

const _uploadPendingKey = 'upload_pending:v1';

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

/// 轮询等待 [predicate] 成立，超时抛出便于定位。
Future<void> _waitFor(
  Future<bool> Function() predicate, {
  String? because,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await _pump();
  }
  fail('等待条件超时${because == null ? '' : '：$because'}');
}

Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

({Directory cache, Directory support, UploadStaging staging})
    _buildStagingFixture() {
  final cache = Directory.systemTemp.createTempSync('pdd-cache-');
  final support = Directory.systemTemp.createTempSync('pdd-support-');
  final staging = UploadStaging(
    temporaryDirectoryProvider: () async => cache,
    supportDirectoryProvider: () async => support,
  );
  return (cache: cache, support: support, staging: staging);
}

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

/// 可控的 OSS 假客户端：objectExists 恒 false，上传可被 [gate] 挂起。
class _FakeOssClient extends OssClient {
  _FakeOssClient({Completer<void>? gate}) : _gate = gate;

  final Completer<void>? _gate;

  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<bool> objectExists(String path, UserSession session) async => false;

  @override
  Future<void> cancelTransfer(String taskId) async {}

  @override
  Future<void> uploadFile(
    String path,
    String localPath,
    UserSession session, {
    required String taskId,
    void Function(int transferredBytes, int totalBytes)? onProgress,
  }) async {
    onProgress?.call(1, 1);
    final gate = _gate;
    if (gate != null) await gate.future;
  }
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

TransferTask _pendingUploadTask({
  required String id,
  required String sourcePath,
  String targetDir = 'shared/',
  String? batchId = 'batch-1',
}) {
  return TransferTask(
    id: id,
    name: 'photo.jpg',
    type: TransferTaskType.upload,
    status: TransferTaskStatus.pending,
    progress: 0,
    target: '全部文件',
    targetDir: targetDir,
    sourcePath: sourcePath,
    batchId: batchId,
    totalBytes: 10,
  );
}

void main() {
  tearDown(() {
    // 清理测试产生的临时目录
    for (final dir in Directory.systemTemp.listSync().whereType<Directory>()) {
      if (dir.path.contains('pdd-cache-') ||
          dir.path.contains('pdd-support-')) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  });

  group('UploadStaging', () {
    test('缓存目录内文件迁移到 staging 并移除原文件', () async {
      final fixture = _buildStagingFixture();
      final source = File('${fixture.cache.path}/shared-import/a.jpg');
      await source.parent.create(recursive: true);
      await source.writeAsString('hello');

      final migrated = await fixture.staging.migrateIfNeeded(
        source.path,
        'upload-1',
      );

      expect(migrated, contains('upload-staging'));
      expect(migrated, contains('upload-1-a.jpg'));
      expect(await File(migrated).readAsString(), 'hello');
      expect(await source.exists(), isFalse);
      expect(await fixture.staging.isInStaging(migrated), isTrue);
      expect(await fixture.staging.isInStaging(source.path), isFalse);
    });

    test('持久路径不迁移，原样返回', () async {
      final fixture = _buildStagingFixture();
      final persistent = Directory.systemTemp.createTempSync('pdd-keep-');
      addTearDown(() {
        try {
          persistent.deleteSync(recursive: true);
        } catch (_) {}
      });
      final source = File('${persistent.path}/local.jpg');
      await source.writeAsString('data');

      final migrated =
          await fixture.staging.migrateIfNeeded(source.path, 'upload-2');

      expect(migrated, source.path);
      expect(await source.exists(), isTrue);
    });

    test('cleanup 只删除 staging 目录内的文件', () async {
      final fixture = _buildStagingFixture();
      final inStaging = File(
        '${fixture.support.path}${Platform.pathSeparator}'
        'upload-staging${Platform.pathSeparator}upload-3-x.jpg',
      );
      await inStaging.parent.create(recursive: true);
      await inStaging.writeAsString('x');
      final outside = File('${fixture.cache.path}/keep.jpg');
      await outside.writeAsString('keep');

      await fixture.staging.cleanup(inStaging.path);
      await fixture.staging.cleanup(outside.path);
      await fixture.staging.cleanup(null);

      expect(await inStaging.exists(), isFalse);
      expect(await outside.exists(), isTrue);
    });
  });

  group('AppController 上传任务持久化', () {
    test('入队即写入 upload_pending，缓存源文件迁移到 staging', () async {
      final fixture = _buildStagingFixture();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = AppController(
        sessionRepository: MemorySessionRepository(),
        uploadStaging: fixture.staging,
      );
      addTearDown(controller.dispose);
      await controller.bootstrap();

      final source = File('${fixture.cache.path}/shared-import/a.jpg');
      await source.parent.create(recursive: true);
      await source.writeAsString('hello');
      await controller.uploadFile(
        fileName: 'a.jpg',
        localPath: source.path,
        fileSize: 5,
      );
      await _waitFor(
        () async => controller.tasks.first.status ==
            TransferTaskStatus.failed,
        because: '无会话时任务应快速失败',
      );

      final raw = (await _prefs()).getString(_uploadPendingKey);
      expect(raw, isNotNull);
      final records = jsonDecode(raw!) as List;
      expect(records, hasLength(1));
      final record = records.first as Map;
      expect(record['type'], 'upload');
      expect(record['targetDir'], 'shared/');
      final persistedSource = record['sourcePath'] as String;
      expect(persistedSource, contains('upload-staging'));
      expect(await File(persistedSource).exists(), isTrue);
      // 分享缓存拷贝经 move 迁移后被清理。
      expect(await source.exists(), isFalse);
    });

    test('任务成功后记录清空且 staging 文件被清理', () async {
      final fixture = _buildStagingFixture();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final controller = AppController(
        sessionRepository: _FakeSessionRepository(_remoteSession()),
        ossClient: _FakeOssClient(),
        uploadStaging: fixture.staging,
      );
      addTearDown(controller.dispose);
      await controller.bootstrap();

      final source = File('${fixture.cache.path}/shared-import/b.jpg');
      await source.parent.create(recursive: true);
      await source.writeAsString('payload');
      await controller.uploadFile(
        fileName: 'b.jpg',
        localPath: source.path,
        fileSize: 7,
      );
      await _waitFor(
        () async => controller.tasks.first.status ==
            TransferTaskStatus.success,
        because: '假 OSS 客户端应立即成功',
      );

      final raw = (await _prefs()).getString(_uploadPendingKey);
      expect(raw, '[]');
      final recordSource = controller.tasks.first.sourcePath!;
      expect(await File(recordSource).exists(), isFalse);
    });

    test('取消后记录移除', () async {
      final fixture = _buildStagingFixture();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final gate = Completer<void>();
      final controller = AppController(
        sessionRepository: _FakeSessionRepository(_remoteSession()),
        ossClient: _FakeOssClient(gate: gate),
        uploadStaging: fixture.staging,
      );
      addTearDown(controller.dispose);
      await controller.bootstrap();

      final source = File('${fixture.cache.path}/shared-import/c.jpg');
      await source.parent.create(recursive: true);
      await source.writeAsString('payload');
      await controller.uploadFile(
        fileName: 'c.jpg',
        localPath: source.path,
        fileSize: 7,
      );
      await _waitFor(
        () async => controller.tasks.first.status ==
            TransferTaskStatus.running,
        because: '上传应被 gate 挂起在 running 状态',
      );
      // running 状态本身也应已写入持久化记录。
      expect(
        ((jsonDecode((await _prefs()).getString(_uploadPendingKey)!)
                    as List))
                .length,
        1,
      );
      controller.cancelTask(controller.tasks.first.id);
      await _waitFor(
        () async => controller.tasks.first.status ==
            TransferTaskStatus.canceled,
      );
      gate.complete();

      await _waitFor(
        () async => (await _prefs()).getString(_uploadPendingKey) == '[]',
        because: '取消后未完成记录应清空',
      );
    });

    test('冷启动恢复：源文件存在转已中断，保留目标目录与批次', () async {
      final fixture = _buildStagingFixture();
      final stagingDir = Directory(
        '${fixture.support.path}${Platform.pathSeparator}upload-staging',
      )..createSync(recursive: true);
      final source = File('${stagingDir.path}/upload-9-photo.jpg');
      await source.writeAsString('x');
      final task = _pendingUploadTask(id: 'upload-9', sourcePath: source.path);
      SharedPreferences.setMockInitialValues(<String, Object>{
        _uploadPendingKey: jsonEncode([task.toJson()]),
      });
      final controller = AppController(
        sessionRepository: MemorySessionRepository(),
        uploadStaging: fixture.staging,
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();

      final restored = controller.tasks.first;
      expect(restored.status, TransferTaskStatus.interrupted);
      expect(restored.message, '已中断');
      expect(restored.targetDir, 'shared/');
      expect(restored.batchId, 'batch-1');
      expect(restored.progress, 0);
      // 已中断任务保留在持久化记录中，等待用户决策。
      final raw = (await _prefs()).getString(_uploadPendingKey);
      expect((jsonDecode(raw!) as List), hasLength(1));
    });

    test('冷启动恢复：源文件缺失转失败并清理记录', () async {
      final fixture = _buildStagingFixture();
      final task = _pendingUploadTask(
        id: 'upload-10',
        sourcePath: '/nonexistent/photo.jpg',
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        _uploadPendingKey: jsonEncode([task.toJson()]),
      });
      final controller = AppController(
        sessionRepository: MemorySessionRepository(),
        uploadStaging: fixture.staging,
      );
      addTearDown(controller.dispose);

      await controller.bootstrap();

      final restored = controller.tasks.first;
      expect(restored.status, TransferTaskStatus.failed);
      expect(restored.error, '源文件已丢失');
      await _waitFor(
        () async => (await _prefs()).getString(_uploadPendingKey) == '[]',
        because: '缺失源文件的任务应从持久化记录清理',
      );
    });

    test('放弃已中断任务转已取消并清理 staging 文件与记录', () async {
      final fixture = _buildStagingFixture();
      final stagingDir = Directory(
        '${fixture.support.path}${Platform.pathSeparator}upload-staging',
      )..createSync(recursive: true);
      final source = File('${stagingDir.path}/upload-11-photo.jpg');
      await source.writeAsString('x');
      final task = _pendingUploadTask(id: 'upload-11', sourcePath: source.path);
      SharedPreferences.setMockInitialValues(<String, Object>{
        _uploadPendingKey: jsonEncode([task.toJson()]),
      });
      final controller = AppController(
        sessionRepository: MemorySessionRepository(),
        uploadStaging: fixture.staging,
      );
      addTearDown(controller.dispose);
      await controller.bootstrap();
      expect(controller.tasks.first.status, TransferTaskStatus.interrupted);

      // 放弃：转已取消并清理 staging 文件，记录移除。
      controller.abandonInterruptedUpload('upload-11');
      await _waitFor(
        () async => controller.tasks.first.status ==
            TransferTaskStatus.canceled,
      );
      await _waitFor(() async => !await source.exists(),
          because: '放弃后 staging 文件应被清理');
      await _waitFor(
        () async => (await _prefs()).getString(_uploadPendingKey) == '[]',
        because: '放弃后未完成记录应清空',
      );
    });

    test('继续上传按原目标目录重新入队（无会话时失败但记录保留）', () async {
      final fixture = _buildStagingFixture();
      final stagingDir = Directory(
        '${fixture.support.path}${Platform.pathSeparator}upload-staging',
      )..createSync(recursive: true);
      final source = File('${stagingDir.path}/upload-12-photo.jpg');
      await source.writeAsString('x');
      final task = _pendingUploadTask(id: 'upload-12', sourcePath: source.path);
      SharedPreferences.setMockInitialValues(<String, Object>{
        _uploadPendingKey: jsonEncode([task.toJson()]),
      });
      final controller = AppController(
        sessionRepository: MemorySessionRepository(),
        uploadStaging: fixture.staging,
      );
      addTearDown(controller.dispose);
      await controller.bootstrap();
      expect(controller.tasks.first.status, TransferTaskStatus.interrupted);

      // 继续上传：重新入队后因无会话而失败，但记录保留（targetDir 不变）。
      controller.resumeInterruptedUpload('upload-12');
      await _waitFor(
        () async => controller.tasks.first.status ==
            TransferTaskStatus.failed,
        because: '无会话时继续上传应重新入队并快速失败',
      );
      expect(controller.tasks.first.error, contains('请先登录'));
      expect(await source.exists(), isTrue);
      final raw = (await _prefs()).getString(_uploadPendingKey);
      expect(jsonDecode(raw!) as List, hasLength(1));
      expect(
        (jsonDecode(raw) as List).first['targetDir'],
        'shared/',
      );
    });

    test('批量入口逐个调用单任务操作', () async {
      final fixture = _buildStagingFixture();
      final stagingDir = Directory(
        '${fixture.support.path}${Platform.pathSeparator}upload-staging',
      )..createSync(recursive: true);
      final sources = <File>[
        for (var index = 0; index < 3; index++)
          File('${stagingDir.path}/upload-1$index-photo$index.jpg')
            ..writeAsStringSync('x$index'),
      ];
      SharedPreferences.setMockInitialValues(<String, Object>{
        _uploadPendingKey: jsonEncode([
          for (var index = 0; index < 3; index++)
            _pendingUploadTask(
              id: 'upload-2$index',
              sourcePath: sources[index].path,
              batchId: 'batch-shared',
            ).toJson(),
        ]),
      });
      final controller = AppController(
        sessionRepository: MemorySessionRepository(),
        uploadStaging: fixture.staging,
      );
      addTearDown(controller.dispose);
      await controller.bootstrap();
      expect(controller.tasks.length, 3);

      controller.abandonAllInterruptedUploads();
      await _waitFor(
        () async => controller
            .tasks
            .every((task) => task.status == TransferTaskStatus.canceled),
      );
      for (var index = 0; index < sources.length; index++) {
        await _waitFor(() async => !await sources[index].exists(),
            because: '第 $index 个 staging 文件应被清理');
      }
      expect(controller.interruptedUploadTaskIds, isEmpty);
      await _waitFor(
        () async => (await _prefs()).getString(_uploadPendingKey) == '[]',
      );
    });
  });
}
