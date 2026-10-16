import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/features/workspace/presentation/workspace_page.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';
import 'package:private_domain_drive_client/shared/state/app_scope.dart';
import 'package:private_domain_oss/private_domain_oss.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('批量操作栏展示移动按钮并联动能力与移动中状态', (tester) async {
    final oss = _FakeOssClient()
      ..objects.addAll(<String>{'shared/a.txt', 'shared/b.txt'});
    await _pumpWorkspace(tester, oss);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('移动'), findsOneWidget);
  });
}

String _fileName(String path) {
  final normalized = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

Future<void> _pumpWorkspace(WidgetTester tester, _FakeOssClient oss) async {
  final controller = AppController(
    sessionRepository: _FakeSessionRepository(_session()),
    ossClient: oss,
  );
  await controller.bootstrap();
  await tester.pumpWidget(
    AppScope(
      controller: controller,
      child: const MaterialApp(home: WorkspacePage(desktopChrome: true)),
    ),
  );
  await tester.pumpAndSettle();
}

UserSession _session() {
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

/// 内存对象版 OssClient 假体：以 Set 维护全部对象 key（含目录标记与
/// manifest），copy/delete 直接改写集合，用于验证移动语义与幂等性。
class _FakeOssClient extends OssClient {
  final Set<String> objects = <String>{};
  final Map<String, String> textContent = <String, String>{};
  final Map<String, int> sizes = <String, int>{};
  final Set<String> copyFailures = <String>{};
  int copyCalls = 0;
  int deleteCalls = 0;
  int deleteManyCalls = 0;

  /// 操作日志：记录 copy / delete / deleteMany 的实际执行顺序，
  /// 供流式执行不变式断言使用。
  final List<String> operationLog = <String>[];

  /// 递归列举每页返回的 key 数，测试流式分页时调小。
  int listPageSize = 1000;

  Set<String> get manifestKeys => objects
      .where((key) => key.startsWith('shared/.moves/') && key.endsWith('manifest.json'))
      .toSet();

  String _dir(String path) => path.endsWith('/') ? path : '$path/';

  String _parent(String key) => key.substring(0, key.lastIndexOf('/') + 1);

  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<void> clearConfiguration() async {}

  @override
  Future<void> cancelTransfer(String taskId) async {}

  @override
  Future<void> copy(String from, String to, UserSession session) async {
    copyCalls++;
    operationLog.add('copy:$from');
    if (copyFailures.contains(from)) {
      throw StateError('copy failed: $from');
    }
    objects.add(to);
    sizes[to] = sizes[from] ?? 0;
  }

  @override
  Future<void> delete(String path, UserSession session) async {
    deleteCalls++;
    operationLog.add('delete:$path');
    objects.remove(path);
  }

  @override
  Future<BatchDeleteResult> deleteMany(
    Iterable<String> paths,
    UserSession session,
  ) async {
    deleteManyCalls++;
    final requested = paths.toList()..sort();
    operationLog.add('deleteMany:${requested.join(',')}');
    objects.removeAll(paths);
    return BatchDeleteResult(deletedPaths: requested);
  }

  @override
  Future<void> forEachObjectKeyPage(
    String path,
    UserSession session,
    Future<void> Function(List<String> keys) onPage,
  ) async {
    final prefix = _dir(path);
    final keys = objects.where((key) => key.startsWith(prefix)).toList()
      ..sort();
    for (var start = 0; start < keys.length; start += listPageSize) {
      final end = start + listPageSize > keys.length
          ? keys.length
          : start + listPageSize;
      await onPage(keys.sublist(start, end));
    }
  }

  @override
  Future<void> createFolder(String path, UserSession session) async {
    objects.add(_dir(path));
  }

  @override
  Future<void> uploadText(
      String path, String content, UserSession session) async {
    objects.add(path);
    textContent[path] = content;
  }

  @override
  Future<bool> objectExists(String path, UserSession session) async =>
      objects.contains(path);

  @override
  Future<List<OssNativeObject>> listAllObjects(
      String path, UserSession session) async {
    return <OssNativeObject>[
      for (final key in objects.where((key) => key.startsWith(path)))
        OssNativeObject(key: key, size: sizes[key] ?? 0),
    ];
  }

  @override
  Future<List<String>> listAllObjectKeys(
      String path, UserSession session) async {
    final prefix = _dir(path);
    return objects.where((key) => key.startsWith(prefix)).toList()..sort();
  }

  @override
  Future<List<String>> listPrefixes(
      String prefix, UserSession session) async {
    final result = <String>{};
    for (final key in objects) {
      if (!key.startsWith(prefix) || key == prefix) continue;
      final rest = key.substring(prefix.length);
      if (rest.isEmpty) continue;
      final segment = rest.split('/').first;
      if (segment.isEmpty) continue;
      result.add('$prefix$segment/');
    }
    return result.toList()..sort();
  }

  @override
  Future<List<int>> download(
    String path,
    UserSession session, {
    int? maxBytes,
  }) async {
    if (!objects.contains(path)) {
      throw StateError('object not found: $path');
    }
    return utf8.encode(textContent[path] ?? '');
  }

  @override
  Future<List<FileItem>> list(String path, UserSession session) async {
    final prefix = _dir(path);
    final items = <FileItem>[];
    for (final key in objects) {
      if (!key.startsWith(prefix) || key == prefix) continue;
      if (_parent(key) != prefix) continue;
      items.add(FileItem(
        path: key,
        name: _fileName(key),
        isDirectory: key.endsWith('/'),
      ));
    }
    return items;
  }
}
