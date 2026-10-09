import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/features/workspace/presentation/workspace_page.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';
import 'package:private_domain_drive_client/shared/state/app_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  FileItem file(String path) => FileItem(
        path: path,
        name: _fileName(path),
        isDirectory: false,
      );

  FileItem dir(String path) => FileItem(
        path: path,
        name: _fileName(path),
        isDirectory: true,
      );

  testWidgets('移动单个文件：复制到目标后删除源', (tester) async {
    final oss = _FakeOssClient()..objects.addAll(<String>{'shared/a.txt'});
    final controller = await _pump(tester, oss);

    await controller.moveItems(<FileItem>[file('shared/a.txt')], 'shared/dst/');

    expect(oss.objects, <String>{'shared/dst/a.txt'});
    expect(oss.manifestKeys, isEmpty);
  });

  testWidgets('移动文件夹递归展开全部子对象并保留层级', (tester) async {
    final oss = _FakeOssClient()
      ..objects.addAll(<String>{
        'shared/src/',
        'shared/src/x.txt',
        'shared/src/sub/',
        'shared/src/sub/y.txt',
      });
    final controller = await _pump(tester, oss);

    await controller.moveItems(<FileItem>[dir('shared/src/')], 'shared/dst/');

    expect(oss.objects, <String>{
      'shared/dst/src/',
      'shared/dst/src/x.txt',
      'shared/dst/src/sub/',
      'shared/dst/src/sub/y.txt',
    });
    expect(oss.manifestKeys, isEmpty);
  });

  testWidgets('移动空文件夹：缺少目录标记时补建目标标记', (tester) async {
    final oss = _FakeOssClient()
      ..objects.addAll(<String>{'shared/src/', 'shared/other.txt'});
    final controller = await _pump(tester, oss);

    await controller.moveItems(<FileItem>[dir('shared/src/')], 'shared/dst/');

    expect(oss.objects, <String>{'shared/dst/src/', 'shared/other.txt'});
  });

  testWidgets('同时选中父文件夹与其子项时只搬运一次', (tester) async {
    final oss = _FakeOssClient()
      ..objects.addAll(<String>{
        'shared/src/',
        'shared/src/x.txt',
        'shared/src/sub/y.txt',
      });
    final controller = await _pump(tester, oss);

    await controller.moveItems(
      <FileItem>[dir('shared/src/'), file('shared/src/x.txt')],
      'shared/dst/',
    );

    // 3 次对象复制 + 1 次删除 manifest（成功收尾）。
    expect(oss.copyCalls, 3);
    expect(oss.deleteCalls, 4);
    expect(oss.objects.contains('shared/dst/src/x.txt'), isTrue);
  });

  testWidgets('目标为源目录的子目录时拒绝且不发出请求', (tester) async {
    final oss = _FakeOssClient()
      ..objects.addAll(<String>{'shared/src/', 'shared/src/x.txt'});
    final controller = await _pump(tester, oss);

    await expectLater(
      controller.moveItems(<FileItem>[dir('shared/src/')], 'shared/src/sub/'),
      throwsStateError,
    );
    expect(oss.copyCalls, 0);
    expect(oss.deleteCalls, 0);
  });

  testWidgets('目标与源所在目录相同时视为无需移动', (tester) async {
    final oss = _FakeOssClient()..objects.addAll(<String>{'shared/a.txt'});
    final controller = await _pump(tester, oss);

    await expectLater(
      controller.moveItems(<FileItem>[file('shared/a.txt')], 'shared/'),
      throwsStateError,
    );
    expect(oss.copyCalls, 0);
  });

  testWidgets('同名冲突保留两者：自动追加序号且不覆盖', (tester) async {
    final oss = _FakeOssClient()
      ..objects.addAll(<String>{'shared/a.txt', 'shared/dst/a.txt'});
    final controller = await _pump(tester, oss);

    final future = controller.moveItems(
      <FileItem>[file('shared/a.txt')],
      'shared/dst/',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留两者'));
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    final summary = await future;

    expect(summary!.hasFailures, isFalse);
    expect(oss.objects, <String>{'shared/dst/a.txt', 'shared/dst/a（1）.txt'});
  });

  testWidgets('同名冲突跳过：保留源文件', (tester) async {
    final oss = _FakeOssClient()
      ..objects.addAll(<String>{'shared/a.txt', 'shared/dst/a.txt'});
    final controller = await _pump(tester, oss);

    final future = controller.moveItems(
      <FileItem>[file('shared/a.txt')],
      'shared/dst/',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳过'));
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    final summary = await future;

    expect(summary, isNotNull);
    expect(oss.objects, <String>{'shared/a.txt', 'shared/dst/a.txt'});
  });

  testWidgets('冲突处置选择取消整个移动时不产生任何搬运', (tester) async {
    final oss = _FakeOssClient()
      ..objects.addAll(<String>{'shared/a.txt', 'shared/dst/a.txt'});
    final controller = await _pump(tester, oss);

    final future = controller.moveItems(
      <FileItem>[file('shared/a.txt')],
      'shared/dst/',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消整个移动'));
    await tester.pumpAndSettle();
    final summary = await future;

    expect(summary, isNull);
    expect(oss.copyCalls, 0);
    expect(oss.objects, <String>{'shared/a.txt', 'shared/dst/a.txt'});
  });

  testWidgets('移动失败时保留 manifest，继续操作幂等收敛', (tester) async {
    final oss = _FakeOssClient()
      ..objects.addAll(<String>{
        'shared/a.txt',
        'shared/b.txt',
      })
      ..copyFailures.add('shared/b.txt');
    final controller = await _pump(tester, oss);

    final summary = await controller.moveItems(
      <FileItem>[file('shared/a.txt'), file('shared/b.txt')],
      'shared/dst/',
    );

    expect(summary!.hasFailures, isTrue);
    expect(oss.manifestKeys, hasLength(1));
    final pending = await controller.listPendingMoves();
    expect(pending, hasLength(1));
    expect(pending.first.sourcePrefixes, <String>['shared/a.txt', 'shared/b.txt']);

    // 模拟故障恢复后重跑：全部对象收敛到目标位置，manifest 删除。
    oss.copyFailures.clear();
    final resumeSummary = await controller.resumePendingMove(pending.first);
    expect(resumeSummary.hasFailures, isFalse);
    expect(oss.objects, <String>{'shared/dst/a.txt', 'shared/dst/b.txt'});
    expect(oss.manifestKeys, isEmpty);
    expect(await controller.listPendingMoves(), isEmpty);
  });

  testWidgets('撤销移动：已搬运对象反向搬回，源位置被占用时自动改名', (tester) async {
    final oss = _FakeOssClient()
      ..objects.addAll(<String>{'shared/a.txt', 'shared/b.txt'})
      ..copyFailures.add('shared/b.txt');
    final controller = await _pump(tester, oss);

    // a.txt 成功搬运，b.txt 复制失败留下 manifest。
    await controller.moveItems(
      <FileItem>[file('shared/a.txt'), file('shared/b.txt')],
      'shared/dst/',
    );
    // 用户随后在源位置放入新的同名文件，验证撤销不得覆盖。
    oss.objects.add('shared/a.txt');
    final pending = await controller.listPendingMoves();
    expect(pending, hasLength(1));

    final summary = await controller.undoPendingMove(pending.first);
    expect(summary.hasFailures, isFalse);
    expect(oss.objects, <String>{
      'shared/a.txt',
      'shared/a（1）.txt',
      'shared/b.txt',
    });
    expect(oss.manifestKeys, isEmpty);
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

Future<AppController> _pump(
  WidgetTester tester,
  _FakeOssClient oss,
) async {
  final controller = AppController(
    sessionRepository: _FakeSessionRepository(_session()),
    ossClient: oss,
  );
  await controller.bootstrap();
  final navigatorKey = GlobalKey<NavigatorState>();
  controller.setNavigatorKey(navigatorKey);
  await tester.pumpWidget(
    AppScope(
      controller: controller,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    ),
  );
  await tester.pump();
  return controller;
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
  final Set<String> copyFailures = <String>{};
  int copyCalls = 0;
  int deleteCalls = 0;

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
    if (copyFailures.contains(from)) {
      throw StateError('copy failed: $from');
    }
    objects.add(to);
  }

  @override
  Future<void> delete(String path, UserSession session) async {
    deleteCalls++;
    objects.remove(path);
  }

  @override
  Future<BatchDeleteResult> deleteMany(
    Iterable<String> paths,
    UserSession session,
  ) async {
    objects.removeAll(paths);
    return BatchDeleteResult(deletedPaths: paths.toList(growable: false));
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
