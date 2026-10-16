import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:private_domain_drive_client/core/version/app_version.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/settings/application/update_service.dart';
import 'package:private_domain_drive_client/features/settings/infrastructure/github_release_client.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/saved_credentials_store.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/shared/state/app_services.dart';
import 'package:private_domain_drive_client/shared/path_utils.dart' as path_utils;

void main() {
  group('AppServices', () {
    test('启动后恢复显示模式，并保存新的选择', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'theme_mode': 'dark',
      });
      final controller =
          AppServices(
            sessionRepository: MemorySessionRepository(),
            savedCredentialsStore:
                SavedCredentialsStore(storage: InMemoryCredentialsStorage()),
          );

      await controller.bootstrap();
      expect(controller.settingsController.themeMode, ThemeMode.dark);

      await controller.settingsController.setThemeMode(ThemeMode.light);
      expect(
        (await SharedPreferences.getInstance()).getString('theme_mode'),
        'light',
      );
      controller.dispose();
    });

    test('启动后恢复缩略图尺寸，并保存新的选择', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'thumbnail_size': 'large',
      });
      final controller =
          AppServices(
            sessionRepository: MemorySessionRepository(),
            savedCredentialsStore:
                SavedCredentialsStore(storage: InMemoryCredentialsStorage()),
          );

      await controller.bootstrap();
      expect(controller.workspaceController.thumbnailSize, ThumbnailSize.large);

      await controller.workspaceController.setThumbnailSize(ThumbnailSize.small);
      expect(
        (await SharedPreferences.getInstance()).getString('thumbnail_size'),
        'small',
      );
      controller.dispose();
    });

    test('无效缩略图尺寸偏好会使用中档', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'thumbnail_size': 'extra-large',
      });
      final controller =
          AppServices(
            sessionRepository: MemorySessionRepository(),
            savedCredentialsStore:
                SavedCredentialsStore(storage: InMemoryCredentialsStorage()),
          );

      await controller.bootstrap();

      expect(controller.workspaceController.thumbnailSize, ThumbnailSize.medium);
      controller.dispose();
    });

    test('目录浏览会记录目录树并支持返回上级', () async {
      final oss = _FakeOssClient()
        ..itemsByPath['shared/'] = const <FileItem>[
          FileItem(path: 'shared/相册/', name: '相册', isDirectory: true),
        ];
      final controller = await _controller(oss: oss);

      final items = await controller.workspaceController.listDirectory();
      controller.workspaceController.setCurrentPath('shared/相册');

      expect(items.single.name, '相册');
      expect(controller.workspaceController.sidebarDirectories, <String>['shared/相册/']);
      expect(path_utils.parentPathOf(controller.workspaceController.currentPath), 'shared/');
    });

    test('首次加载根目录会通知侧栏刷新', () async {
      final oss = _FakeOssClient()
        ..itemsByPath['shared/'] = const <FileItem>[
          FileItem(path: 'shared/相册/', name: '相册', isDirectory: true),
        ];
      final controller = await _controller(oss: oss);
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.workspaceController.listDirectory();

      expect(notifications, 1);
      expect(controller.workspaceController.sidebarDirectories, <String>['shared/相册/']);
    });

    test('新建文件夹会校验空名称并使用当前目录', () async {
      final oss = _FakeOssClient();
      final controller = await _controller(oss: oss);

      await expectLater(
          controller.workspaceController.createFolder('  '), throwsA(isA<StateError>()));
      await controller.workspaceController.createFolder('资料');

      expect(oss.createdFolders, <String>['shared/资料/']);
      expect(controller.workspaceController.treeRevision, 1);
    });

    test('重命名通过复制后删除完成，并刷新树版本', () async {
      final oss = _FakeOssClient();
      final controller = await _controller(oss: oss);
      const item =
          FileItem(path: 'shared/旧名.txt', name: '旧名.txt', isDirectory: false);

      await controller.workspaceController.renameItem(item, '新名.txt');

      expect(
          oss.copies, <(String, String)>[('shared/旧名.txt', 'shared/新名.txt')]);
      expect(oss.deleted, <String>['shared/旧名.txt']);
      expect(controller.workspaceController.treeRevision, 1);
    });

    test('选中文件夹后会异步统计大小，并复用本次会话缓存', () async {
      final oss = _FakeOssClient()..directorySizes['shared/资料/'] = 3072;
      final controller = await _controller(oss: oss);
      const folder = FileItem(
        path: 'shared/资料/',
        name: '资料',
        isDirectory: true,
      );

      controller.workspaceController.selectItem(folder);
      await Future<void>.delayed(Duration.zero);

      expect(
        controller.workspaceController.directorySizeStatesListenable.value[folder.path]?.size,
        3072,
      );
      expect(oss.directorySizeCalls, 1);

      controller.workspaceController.selectItem(null);
      controller.workspaceController.selectItem(folder);
      await Future<void>.delayed(Duration.zero);
      expect(oss.directorySizeCalls, 1);
    });

    test('多选状态支持范围选择、全选与取消', () async {
      final controller = await _controller();
      const items = <FileItem>[
        FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
        FileItem(path: 'shared/b.txt', name: 'b.txt', isDirectory: false),
        FileItem(path: 'shared/c.txt', name: 'c.txt', isDirectory: false),
      ];

      controller.workspaceController.enterMultiSelection(items.first);
      controller.workspaceController.toggleMultiSelection(items.last,
          visibleItems: items, range: true);
      expect(controller.workspaceController.multiSelectedPaths, <String>{
        'shared/a.txt',
        'shared/b.txt',
        'shared/c.txt',
      });

      controller.workspaceController.clearMultiSelection();
      expect(controller.workspaceController.isMultiSelectionMode, isFalse);
      expect(controller.workspaceController.multiSelectedPaths, isEmpty);
    });

    test('键盘方向选择按目录排序移动单个选中项', () async {
      final controller = await _controller();
      const items = <FileItem>[
        FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
        FileItem(path: 'shared/b.txt', name: 'b.txt', isDirectory: false),
        FileItem(path: 'shared/c.txt', name: 'c.txt', isDirectory: false),
      ];

      controller.workspaceController.selectItem(items.first);
      expect(
        controller.workspaceController.moveSelection(items, offset: 1),
        isTrue,
      );
      expect(controller.workspaceController.selectedItem?.path, 'shared/b.txt');
      expect(controller.workspaceController.multiSelectedPaths, isEmpty);

      controller.workspaceController.moveSelection(items, offset: 1);
      expect(controller.workspaceController.selectedItem?.path, 'shared/c.txt');
      expect(controller.workspaceController.multiSelectedPaths, isEmpty);

      controller.workspaceController.moveSelection(items, offset: -1);
      expect(controller.workspaceController.selectedItem?.path, 'shared/b.txt');
      expect(controller.workspaceController.multiSelectedPaths, isEmpty);
    });
  });

  group('强制升级门禁', () {
    AppServices controllerWithGate(
      _GateHarness harness, {
      bool disableStartupUpdateCheck = false,
    }) {
      final controller = AppServices(
        sessionRepository: MemorySessionRepository(),
        savedCredentialsStore:
            SavedCredentialsStore(storage: InMemoryCredentialsStorage()),
        updateService: harness.service,
        disableStartupUpdateCheck: disableStartupUpdateCheck,
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('当前版本低于最低支持版本时门禁生效', () async {
      final harness = _GateHarness(currentVersion: '1.1.4');
      final controller = controllerWithGate(harness);
      expect(controller.settingsController.forcedUpgradeActive, isFalse);

      await controller.settingsController.checkForcedUpgradeGate();

      expect(controller.settingsController.forcedUpgradeActive, isTrue);
      expect(controller.settingsController.forcedUpgradeResult!.minSupportedVersion, '1.2.0');
      expect(controller.settingsController.forcedUpgradeResult!.availableUpdate, isNotNull);
    });

    test('不低于最低支持版本时放行', () async {
      final harness = _GateHarness(currentVersion: '1.2.0');
      final controller = controllerWithGate(harness);

      await controller.settingsController.checkForcedUpgradeGate();

      expect(controller.settingsController.forcedUpgradeActive, isFalse);
      expect(controller.settingsController.forcedUpgradeResult, isNull);
    });

    test('检查失败静默放行且不缓存结论，下次检查重新判定', () async {
      final harness = _GateHarness(currentVersion: '1.1.4')..offline = true;
      final controller = controllerWithGate(harness);

      await controller.settingsController.checkForcedUpgradeGate();
      expect(controller.settingsController.forcedUpgradeActive, isFalse);

      harness.offline = false;
      await controller.settingsController.checkForcedUpgradeGate();
      expect(controller.settingsController.forcedUpgradeActive, isTrue);
    });

    test('拦截期间重试失败保持拦截，门槛解除后重试放行', () async {
      final harness = _GateHarness(currentVersion: '1.1.4');
      final controller = controllerWithGate(harness);
      await controller.settingsController.checkForcedUpgradeGate();
      expect(controller.settingsController.forcedUpgradeActive, isTrue);

      harness.offline = true;
      await controller.settingsController.checkForcedUpgradeGate();
      expect(controller.settingsController.forcedUpgradeActive, isTrue);

      harness.offline = false;
      harness.minSupportedVersion = '1.0.0';
      await controller.settingsController.checkForcedUpgradeGate();
      expect(controller.settingsController.forcedUpgradeActive, isFalse);
    });

    test('调试开关跳过启动检查也不拦截', () async {
      final harness = _GateHarness(currentVersion: '1.1.4');
      final controller =
          controllerWithGate(harness, disableStartupUpdateCheck: true);

      await controller.settingsController.checkForcedUpgradeGate();

      expect(harness.requests, 0);
      expect(controller.settingsController.forcedUpgradeActive, isFalse);
    });
  });
}

/// 门禁检查用假服务：以可变状态模拟离线、门槛调整与请求计数。
class _GateHarness {
  _GateHarness({required this.currentVersion});

  static const _releasesPath =
      '/repos/littlefisher666/private-domain-drive-client/releases';

  final String currentVersion;
  String minSupportedVersion = '1.2.0';
  bool offline = false;
  int requests = 0;

  late final UpdateService service = UpdateService(
    versionReader: _FixedAppVersionReader(currentVersion),
    releaseClient: GithubReleaseClient(
      client: MockClient((request) async {
        requests += 1;
        if (offline) {
          throw http.ClientException('mock offline');
        }
        if (request.url.path == _releasesPath) {
          return _jsonResponse(<Map<String, dynamic>>[
            {
              'tag_name': 'android/v$minSupportedVersion',
              'assets': [
                {
                  'name': 'private-domain-drive-update.json',
                  'browser_download_url':
                      'https://example.com/private-domain-drive-update.json',
                },
              ],
            },
          ]);
        }
        return _jsonResponse(<String, dynamic>{
          'version': minSupportedVersion,
          'notes': '',
          'minSupportedVersion': minSupportedVersion,
          'assets': {
            'android': {
              'name': 'private-domain-drive-android-v$minSupportedVersion.apk',
              'url': 'https://example.com/android.apk',
              'digest': 'sha256:abc',
            },
          },
        });
      }),
    ),
  );
}

class _FixedAppVersionReader implements AppVersionReader {
  _FixedAppVersionReader(this.version);

  final String version;

  @override
  Future<AppVersion> read() async => AppVersion(name: version, buildNumber: '1');
}

http.Response _jsonResponse(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json'},
    );

Future<AppServices> _controller({_FakeOssClient? oss}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final controller = AppServices(
    sessionRepository: _FakeSessionRepository(_remoteSession()),
    ossClient: oss ?? _FakeOssClient(),
  );
  await controller.bootstrap();
  return controller;
}

UserSession _remoteSession() {
  return const UserSession(
    userId: 'test-user',
    account: 'test',
    displayName: '测试成员',
    role: 'member',
    capabilities: Capabilities.standard(),
    rootPrefix: 'shared/',
    ossConfig: OssConfig(
      bucket: 'test-bucket',
      region: 'cn-hangzhou',
      endpoint: 'oss-cn-hangzhou.aliyuncs.com',
      rootPrefix: 'shared/',
    ),
    credentials: OssCredentials(
      accessKeyId: 'id',
      accessKeySecret: 'secret',
    ),
  );
}

class _FakeSessionRepository implements SessionRepository {
  _FakeSessionRepository(this.session);

  final UserSession session;

  @override
  Future<void> logout() async {}

  @override
  Future<UserSession> login(
          {required String account, required String password}) async =>
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
  final Map<String, List<FileItem>> itemsByPath = <String, List<FileItem>>{};
  final Map<String, List<String>> objectKeysByPath = <String, List<String>>{};
  final Map<String, int> directorySizes = <String, int>{};
  final Set<String> existingPaths = <String>{};
  int directorySizeCalls = 0;
  final List<String> createdFolders = <String>[];
  final List<String> deleted = <String>[];
  final List<(String, String)> copies = <(String, String)>[];
  final List<({String path, String localPath})> uploads =
      <({String path, String localPath})>[];
  List<int> downloadResult = const <int>[];
  Completer<void>? downloadGate;
  Object? downloadToFileError;
  List<(int, int)> progressReports = <(int, int)>[];
  Duration progressInterval = Duration.zero;
  final List<String> canceledTaskIds = <String>[];

  @override
  Future<List<FileItem>> list(String path, UserSession session) async =>
      itemsByPath[path] ?? const <FileItem>[];

  @override
  Future<List<String>> listAllObjectKeys(
          String path, UserSession session) async =>
      objectKeysByPath[path] ?? const <String>[];

  @override
  Future<int> calculateDirectorySize(String path, UserSession session) async {
    directorySizeCalls++;
    return directorySizes[path] ?? 0;
  }

  @override
  Future<void> createFolder(String path, UserSession session) async {
    createdFolders.add(path);
  }

  @override
  Future<void> copy(String from, String to, UserSession session) async {
    copies.add((from, to));
  }

  @override
  Future<bool> objectExists(String path, UserSession session) async =>
      existingPaths.contains(path);

  @override
  Future<void> delete(String path, UserSession session) async {
    deleted.add(path);
  }

  @override
  Future<BatchDeleteResult> deleteMany(
    Iterable<String> paths,
    UserSession session,
  ) async {
    final values = paths.toList(growable: false);
    deleted.addAll(values);
    return BatchDeleteResult(deletedPaths: values);
  }

  @override
  Future<void> uploadFile(
    String path,
    String localPath,
    UserSession session, {
    required String taskId,
    void Function(int transferredBytes, int totalBytes)? onProgress,
  }) async {
    uploads.add((path: path, localPath: localPath));
    // 不读取真实文件，保证 testWidgets 的 FakeAsync 环境下可完成。
    onProgress?.call(1, 1);
  }

  @override
  Future<List<int>> download(
    String path,
    UserSession session, {
    int? maxBytes,
  }) async =>
      downloadResult;

  @override
  Future<List<String>> listPrefixes(
    String prefix,
    UserSession session,
  ) async =>
      const <String>[];

  @override
  Future<void> downloadToFile(
    String path,
    UserSession session,
    File target, {
    required String taskId,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {
    // 先落盘再等待闸门，模拟流式写入中途被取消/失败的场景。
    await target.parent.create(recursive: true);
    await target.writeAsBytes(<int>[1], flush: true);
    for (final report in progressReports) {
      onProgress(report.$1, report.$2);
      if (progressInterval > Duration.zero) {
        await Future<void>.delayed(progressInterval);
      }
    }
    final gate = downloadGate;
    if (gate != null) await gate.future;
    if (isCanceled()) throw const TransferCanceledException();
    onProgress(1, 1);
    final error = downloadToFileError;
    if (error != null) throw error;
  }

  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<void> clearConfiguration() async {}

  @override
  Future<void> cancelTransfer(String taskId) async {
    canceledTaskIds.add(taskId);
  }
}
