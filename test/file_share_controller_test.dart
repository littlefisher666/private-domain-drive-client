import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/application/session_controller.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/file_share/application/file_share_controller.dart';
import 'package:private_domain_drive_client/features/file_share/domain/file_share_models.dart';
import 'package:private_domain_drive_client/features/file_share/infrastructure/share_cache_store.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _FakeOssClient oss;
  late SessionController sessionController;
  late FileShareController controller;

  const item = FileItem(
    path: 'shared/a.bin',
    name: 'a.bin',
    isDirectory: false,
    size: 4,
  );
  const secondItem = FileItem(
    path: 'shared/b.bin',
    name: 'b.bin',
    isDirectory: false,
    size: 4,
  );

  Future<void> setUpController({
    UserSession? session,
    ShareFilesInvoker? invoker,
  }) async {
    root = Directory.systemTemp.createTempSync('pdd-share-controller-');
    oss = _FakeOssClient();
    sessionController = SessionController(
      sessionRepository: _FakeSessionRepository(session ?? _session()),
      ossClient: oss,
    );
    await sessionController.bootstrap();
    controller = FileShareController(
      sessionController: sessionController,
      ossClient: oss,
      cacheStore: ShareCacheStore(rootResolver: () => root),
      shareInvoker: invoker,
    );
  }

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
    debugDefaultTargetPlatformOverride = null;
  });

  group('分享可用条件', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });

    tearDown(() {
      controller.dispose();
      sessionController.dispose();
    });

    test('Android 且具备下载能力时普通文件可分享', () async {
      await setUpController();
      expect(controller.canShare(item), isTrue);
    });

    test('文件夹、别名与无下载能力不可分享', () async {
      await setUpController();
      expect(
        controller.canShare(
          const FileItem(path: 'shared/dir/', name: 'dir', isDirectory: true),
        ),
        isFalse,
      );
      expect(
        controller.canShare(
          const FileItem(
            path: 'shared/alias/',
            name: 'alias',
            isDirectory: false,
            isAlias: true,
          ),
        ),
        isFalse,
      );

      controller.dispose();
      sessionController.dispose();
      await setUpController(
        session: _session(capabilities: _noDownloadCapabilities()),
      );
      expect(controller.canShare(item), isFalse);
      await expectLater(controller.prepare(item), throwsStateError);
      expect(oss.downloadCalls, 0);
    });

    test('非 Android 平台不可分享', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await setUpController();
      expect(controller.canShare(item), isFalse);
      expect(controller.canShareAll(<FileItem>[item, secondItem]), isFalse);
    });

    test('全部为普通文件时可批量分享，混合文件夹或空选择不可', () async {
      await setUpController();
      expect(controller.canShareAll(<FileItem>[item, secondItem]), isTrue);
      expect(controller.canShareAll(<FileItem>[]), isFalse);
      expect(
        controller.canShareAll(
          <FileItem>[
            item,
            const FileItem(
              path: 'shared/dir/',
              name: 'dir',
              isDirectory: true,
            ),
          ],
        ),
        isFalse,
      );
    });
  });

  group('本地副本准备', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });

    tearDown(() {
      controller.dispose();
      sessionController.dispose();
    });

    test('缓存命中直接复用，不发起下载', () async {
      await setUpController();
      final cached = await controller.lookup(item);
      // 先通过 prepare 生成缓存，再验证第二次命中。
      final first = await controller.prepare(item);
      expect(oss.downloadCalls, 1);
      expect(cached, isNull);

      final second = await controller.prepare(item);
      expect(second.path, first.path);
      expect(oss.downloadCalls, 1);
      expect(controller.progressListenable.value, isNull);
    });

    test('缓存未命中时下载、上报进度并落定缓存', () async {
      await setUpController();
      final progressValues = <ShareProgress>[];
      controller.progressListenable.addListener(() {
        final value = controller.progressListenable.value;
        if (value != null) progressValues.add(value);
      });

      final prepared = await controller.prepare(item);
      expect(oss.downloadCalls, 1);
      expect(await prepared.length(), 4);
      expect(prepared.path, contains('pdd_share_cache'));
      expect(progressValues, isNotEmpty);
      expect(progressValues.last.receivedBytes, 4);
      expect(progressValues.last.totalBytes, 4);
      expect(controller.progressListenable.value, isNull);
    });

    test('多文件依次准备并汇报累计进度', () async {
      await setUpController();
      final progressValues = <ShareProgress>[];
      controller.progressListenable.addListener(() {
        final value = controller.progressListenable.value;
        if (value != null) progressValues.add(value);
      });

      final prepared = await controller.prepareAll(
        <FileItem>[item, secondItem],
      );
      expect(prepared, hasLength(2));
      expect(oss.downloadCalls, 2);
      expect(
        progressValues.any(
          (value) => value.fileCount == 2 && value.fileIndex == 1,
        ),
        isTrue,
      );
      expect(progressValues.last.fileIndex, 2);
      expect(progressValues.last.receivedBytes, 8);
      expect(progressValues.last.totalBytes, 8);
      expect(controller.progressListenable.value, isNull);
    });

    test('多文件准备复用已有缓存，仅下载未命中项', () async {
      await setUpController();
      await controller.prepare(item);
      expect(oss.downloadCalls, 1);

      final prepared = await controller.prepareAll(
        <FileItem>[item, secondItem],
      );
      expect(prepared, hasLength(2));
      expect(oss.downloadCalls, 2);
      expect(prepared.first.path, contains('a.bin'));
      expect(prepared.last.path, contains('b.bin'));
    });

    test('取消准备中止下载并清理临时文件', () async {
      await setUpController();
      oss.waitForCancel = true;
      final target = ShareCacheStore(rootResolver: () => root);
      final cacheFile = await target.fileFor(item);

      final future = controller.prepare(item);
      await oss.started.future;
      expect(controller.isPreparing, isTrue);
      controller.cancelPreparation();

      await expectLater(future, throwsA(isA<FileShareCanceledException>()));
      expect(oss.canceledTaskIds, isNotEmpty);
      expect(await cacheFile.exists(), isFalse);
      expect(await File('${cacheFile.path}.part').exists(), isFalse);
      expect(controller.isPreparing, isFalse);
      expect(controller.progressListenable.value, isNull);
    });
  });

  group('系统分享结果', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });

    tearDown(() {
      controller.dispose();
      sessionController.dispose();
    });

    Future<FileShareOutcome> shareWith(
      Future<ShareResult> Function(List<String>) invoker,
    ) async {
      await setUpController(invoker: invoker);
      return controller.shareFiles(<String>['${root.path}/a.bin']);
    }

    test('success 映射为成功', () async {
      expect(
        await shareWith(
          (_) async => const ShareResult('', ShareResultStatus.success),
        ),
        FileShareOutcome.success,
      );
    });

    test('多文件路径一次性交给分享通道', () async {
      List<String>? received;
      await setUpController(
        invoker: (paths) async {
          received = paths;
          return const ShareResult('', ShareResultStatus.success);
        },
      );

      final outcome = await controller.shareFiles(<String>['/a.bin', '/b.bin']);
      expect(outcome, FileShareOutcome.success);
      expect(received, <String>['/a.bin', '/b.bin']);
    });

    test('dismissed 视为用户取消', () async {
      expect(
        await shareWith(
          (_) async => const ShareResult('', ShareResultStatus.dismissed),
        ),
        FileShareOutcome.canceled,
      );
    });

    test('unavailable 与异常统一映射为失败', () async {
      expect(
        await shareWith((_) async => ShareResult.unavailable),
        FileShareOutcome.failed,
      );
      expect(
        await shareWith((_) async => throw StateError('boom')),
        FileShareOutcome.failed,
      );
    });
  });
}

UserSession _session({Capabilities? capabilities}) {
  return UserSession(
    userId: 'test-user',
    account: 'test',
    displayName: '测试成员',
    role: 'member',
    capabilities: capabilities ?? const Capabilities.standard(),
    rootPrefix: 'shared/',
    ossConfig: const OssConfig(
      bucket: 'test-bucket',
      region: 'cn-hangzhou',
      endpoint: 'oss-cn-hangzhou.aliyuncs.com',
      rootPrefix: 'shared/',
    ),
    credentials: const OssCredentials(
      accessKeyId: 'id',
      accessKeySecret: 'secret',
    ),
  );
}

Capabilities _noDownloadCapabilities() {
  return const Capabilities(
    list: true,
    download: false,
    upload: true,
    delete: true,
    preview: true,
  );
}

class _FakeSessionRepository implements SessionRepository {
  _FakeSessionRepository(this.session);

  final UserSession session;

  @override
  Future<void> logout() async {}

  @override
  Future<UserSession> login({
    required String account,
    required String password,
  }) async =>
      session;

  @override
  Future<UserSession> changePassword({
    required UserSession session,
    required String currentPassword,
    required String newPassword,
  }) async =>
      session.copyWith(mustResetPassword: false);

  @override
  Future<UserSession?> restore() async => session;
}

class _FakeOssClient extends OssClient {
  int downloadCalls = 0;
  bool waitForCancel = false;
  final List<String> canceledTaskIds = <String>[];
  final started = Completer<void>();

  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<void> clearConfiguration() async {}

  @override
  Future<void> downloadToFile(
    String path,
    UserSession session,
    File target, {
    required String taskId,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {
    downloadCalls++;
    if (!started.isCompleted) started.complete();
    if (waitForCancel) {
      while (!isCanceled()) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      throw const TransferCanceledException();
    }
    await target.parent.create(recursive: true);
    await target.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
    onProgress(4, 4);
  }

  @override
  Future<void> cancelTransfer(String taskId) async {
    canceledTaskIds.add(taskId);
  }
}
