import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/features/workspace/presentation/workspace_page.dart';
import 'package:private_domain_drive_client/shared/state/app_scope.dart';
import 'package:private_domain_drive_client/shared/state/app_services.dart';
import 'package:private_domain_oss/private_domain_oss.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 工作区页 widget 测试共用的内存 OSS 与会话夹具。
class FakeWorkspaceOssClient extends OssClient {
  FakeWorkspaceOssClient({
    Map<String, List<FileItem>>? itemsByPath,
  }) : itemsByPath = itemsByPath ?? <String, List<FileItem>>{};

  final Map<String, List<FileItem>> itemsByPath;
  int listCalls = 0;
  int listPrefixCalls = 0;

  /// 非空时在下一次列举中抛出，用于模拟刷新失败。
  Object? listError;

  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<void> copy(String from, String to, UserSession session) async {}

  @override
  Future<void> uploadText(
    String path,
    String content,
    UserSession session,
  ) async {}

  @override
  Future<List<String>> listPrefixes(
    String prefix,
    UserSession session,
  ) async {
    listPrefixCalls++;
    return const <String>[];
  }

  @override
  Future<List<FileItem>> list(String path, UserSession session) async {
    listCalls++;
    final error = listError;
    if (error != null) {
      listError = null;
      throw error;
    }
    return itemsByPath[path] ?? const <FileItem>[];
  }

  @override
  Future<List<String>> listAllObjectKeys(String path, UserSession session) =>
      Future<void>.value().then(
        (_) => const <String>[],
      );

  @override
  Future<List<OssNativeObject>> listAllObjects(
    String path,
    UserSession session,
  ) async =>
      const <OssNativeObject>[];

  @override
  Future<BatchDeleteResult> deleteMany(
    Iterable<String> paths,
    UserSession session,
  ) async =>
      BatchDeleteResult(deletedPaths: paths.toList(growable: false));

  @override
  Future<void> downloadToFile(
    String path,
    UserSession session,
    File target, {
    required String taskId,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
    required bool Function() isCanceled,
  }) async {
    await target.parent.create(recursive: true);
    await target.writeAsBytes(<int>[1], flush: true);
    onProgress(1, 1);
  }

  @override
  Future<void> clearConfiguration() async {}

  @override
  Future<void> cancelTransfer(String taskId) async {}
}

UserSession workspaceTestSession({
  Capabilities capabilities = const Capabilities.standard(),
}) {
  return UserSession(
    userId: 'test-user',
    account: 'test',
    displayName: '测试成员',
    role: 'member',
    capabilities: capabilities,
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

class FakeWorkspaceSessionRepository implements SessionRepository {
  FakeWorkspaceSessionRepository(this.session);

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

Future<AppServices> pumpWorkspace(
  WidgetTester tester,
  List<FileItem> files, {
  bool desktop = true,
  FakeWorkspaceOssClient? oss,
  Map<String, WidgetBuilder>? routes,
  Capabilities capabilities = const Capabilities.standard(),
}) {
  return pumpApp(
    tester,
    WorkspacePage(desktopChrome: desktop),
    oss: oss ??
        FakeWorkspaceOssClient(itemsByPath: <String, List<FileItem>>{
          'shared/': files,
        }),
    routes: routes,
    capabilities: capabilities,
  );
}

Future<AppServices> pumpApp(
  WidgetTester tester,
  Widget home, {
  FakeWorkspaceOssClient? oss,
  Map<String, WidgetBuilder>? routes,
  Capabilities capabilities = const Capabilities.standard(),
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final controller = AppServices(
    sessionRepository: FakeWorkspaceSessionRepository(
      workspaceTestSession(capabilities: capabilities),
    ),
    ossClient: oss ?? FakeWorkspaceOssClient(),
  );
  await controller.bootstrap();
  await tester.pumpWidget(
    AppScope(
      services: controller,
      child: MaterialApp(
        home: home,
        routes: routes ?? const <String, WidgetBuilder>{},
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}
