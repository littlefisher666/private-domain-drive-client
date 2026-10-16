import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/application/session_controller.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/workspace/application/move_controller.dart';
import 'package:private_domain_drive_client/features/workspace/application/workspace_controller.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/domain/move_models.dart';
import 'package:private_domain_drive_client/features/workspace/domain/move_task_entry.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_oss/private_domain_oss.dart';
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

  group('MoveController', () {
    test('移动单个文件：复制到目标后删除源', () async {
      final oss = _FakeOssClient()..objects.addAll(<String>{'shared/a.txt'});
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);

      await move.controller
          .moveItems(<FileItem>[file('shared/a.txt')], 'shared/dst/');

      expect(oss.objects, <String>{'shared/dst/a.txt'});
      expect(oss.manifestKeys, isEmpty);
    });

    test('移动文件夹递归展开全部子对象并保留层级', () async {
      final oss = _FakeOssClient()
        ..objects.addAll(<String>{
          'shared/src/',
          'shared/src/x.txt',
          'shared/src/sub/',
          'shared/src/sub/y.txt',
        });
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);

      await move.controller
          .moveItems(<FileItem>[dir('shared/src/')], 'shared/dst/');

      expect(oss.objects, <String>{
        'shared/dst/src/',
        'shared/dst/src/x.txt',
        'shared/dst/src/sub/',
        'shared/dst/src/sub/y.txt',
      });
      expect(oss.manifestKeys, isEmpty);
    });

    test('移动空文件夹：缺少目录标记时补建目标标记', () async {
      final oss = _FakeOssClient()
        ..objects.addAll(<String>{'shared/src/', 'shared/other.txt'});
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);

      await move.controller
          .moveItems(<FileItem>[dir('shared/src/')], 'shared/dst/');

      expect(oss.objects, <String>{'shared/dst/src/', 'shared/other.txt'});
    });

    test('同时选中父文件夹与其子项时只搬运一次', () async {
      final oss = _FakeOssClient()
        ..objects.addAll(<String>{
          'shared/src/',
          'shared/src/x.txt',
          'shared/src/sub/y.txt',
        });
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);

      await move.controller.moveItems(
        <FileItem>[dir('shared/src/'), file('shared/src/x.txt')],
        'shared/dst/',
      );

      // 3 次对象复制 + 2 次批量删源（目录标记与列举页各一批）+ 1 次删除 manifest。
      expect(oss.copyCalls, 3);
      expect(oss.deleteManyCalls, 2);
      expect(oss.deleteCalls, 1);
      expect(oss.objects.contains('shared/dst/src/x.txt'), isTrue);
    });

    test('目标为源目录的子目录时拒绝且不发出请求', () async {
      final oss = _FakeOssClient()
        ..objects.addAll(<String>{'shared/src/', 'shared/src/x.txt'});
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);

      await expectLater(
        move.controller.moveItems(<FileItem>[dir('shared/src/')], 'shared/src/sub/'),
        throwsStateError,
      );
      expect(oss.copyCalls, 0);
      expect(oss.deleteCalls, 0);
    });

    test('目标与源所在目录相同时视为无需移动', () async {
      final oss = _FakeOssClient()..objects.addAll(<String>{'shared/a.txt'});
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);

      await expectLater(
        move.controller.moveItems(<FileItem>[file('shared/a.txt')], 'shared/'),
        throwsStateError,
      );
      expect(oss.copyCalls, 0);
    });

    testWidgets('同名冲突保留两者：自动追加序号且不覆盖', (tester) async {
      final oss = _FakeOssClient()
        ..objects.addAll(<String>{'shared/a.txt', 'shared/dst/a.txt'});
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);
      final navigatorKey = GlobalKey<NavigatorState>();
      move.controller.setNavigatorKey(navigatorKey);
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );

      final future = move.controller.moveItems(
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
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);
      final navigatorKey = GlobalKey<NavigatorState>();
      move.controller.setNavigatorKey(navigatorKey);
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );

      final future = move.controller.moveItems(
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
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);
      final navigatorKey = GlobalKey<NavigatorState>();
      move.controller.setNavigatorKey(navigatorKey);
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );

      final future = move.controller.moveItems(
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

    test('移动失败时保留 manifest，继续操作幂等收敛', () async {
      final oss = _FakeOssClient()
        ..objects.addAll(<String>{
          'shared/a.txt',
          'shared/b.txt',
        })
        ..copyFailures.add('shared/b.txt');
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);

      final summary = await move.controller.moveItems(
        <FileItem>[file('shared/a.txt'), file('shared/b.txt')],
        'shared/dst/',
      );

      expect(summary!.hasFailures, isTrue);
      expect(oss.manifestKeys, hasLength(1));
      final pending = await move.controller.listPendingMoves();
      expect(pending, hasLength(1));
      expect(pending.first.sourcePrefixes, <String>['shared/a.txt', 'shared/b.txt']);

      // 模拟故障恢复后重跑：全部对象收敛到目标位置，manifest 删除。
      oss.copyFailures.clear();
      final resumeSummary = await move.controller.resumePendingMove(pending.first);
      expect(resumeSummary.hasFailures, isFalse);
      expect(oss.objects, <String>{'shared/dst/a.txt', 'shared/dst/b.txt'});
      expect(oss.manifestKeys, isEmpty);
      expect(await move.controller.listPendingMoves(), isEmpty);
    });

    test('撤销移动：已搬运对象反向搬回，源位置被占用时自动改名', () async {
      final oss = _FakeOssClient()
        ..objects.addAll(<String>{'shared/a.txt', 'shared/b.txt'})
        ..copyFailures.add('shared/b.txt')
        ..sizes['shared/a.txt'] = 5
        ..sizes['shared/b.txt'] = 7;
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);

      // a.txt 成功搬运，b.txt 复制失败留下 manifest。
      await move.controller.moveItems(
        <FileItem>[file('shared/a.txt'), file('shared/b.txt')],
        'shared/dst/',
      );
      // 用户随后在源位置放入同名但内容不同的新文件，验证撤销不得覆盖。
      oss.objects.add('shared/a.txt');
      oss.sizes['shared/a.txt'] = 99;
      final pending = await move.controller.listPendingMoves();
      expect(pending, hasLength(1));

      final summary = await move.controller.undoPendingMove(pending.first);
      expect(summary.hasFailures, isFalse);
      expect(oss.objects, <String>{
        'shared/a.txt',
        'shared/a（1）.txt',
        'shared/b.txt',
      });
      expect(oss.manifestKeys, isEmpty);
    });

    test('撤销中断批次：源目标两侧重复副本直接丢弃而非改名', () async {
      final oss = _FakeOssClient()
        ..objects.addAll(<String>{
          'shared/src/',
          'shared/src/keep.txt',
          'shared/dst/src/',
          'shared/dst/src/keep.txt',
          'shared/dst/src/moved.txt',
        })
        ..sizes['shared/src/keep.txt'] = 5
        ..sizes['shared/dst/src/keep.txt'] = 5
        ..sizes['shared/dst/src/moved.txt'] = 7;
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);

      // 模拟中断批次：keep.txt 已复制到目标但源侧尚未删除；moved.txt 已完成搬运。
      final entry = MoveTaskEntry(
        id: 'task-1',
        sourcePrefixes: <String>['shared/src/'],
        targetPrefix: 'shared/dst/',
        createdAt: DateTime(2026, 1, 1),
      );
      final summary = await move.controller.undoPendingMove(entry);

      expect(summary.hasFailures, isFalse);
      expect(oss.objects, <String>{
        'shared/src/',
        'shared/src/keep.txt',
        'shared/src/moved.txt',
      });
      expect(oss.copyCalls, 1);
      expect(oss.manifestKeys, isEmpty);
    });

    test('流式执行：每个对象的复制先于其源删除', () async {
      final oss = _FakeOssClient()
        ..objects.addAll(<String>{
          'shared/src/',
          'shared/src/a.txt',
          'shared/src/b.txt',
          'shared/src/c.txt',
        })
        ..listPageSize = 2;
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);

      await move.controller
          .moveItems(<FileItem>[dir('shared/src/')], 'shared/dst/');

      expect(oss.objects, <String>{
        'shared/dst/src/',
        'shared/dst/src/a.txt',
        'shared/dst/src/b.txt',
        'shared/dst/src/c.txt',
      });
      // 单对象 copy 先于其源 delete 的不变式在分页流式执行下依旧成立。
      for (final key in <String>[
        'shared/src/a.txt',
        'shared/src/b.txt',
        'shared/src/c.txt',
      ]) {
        final copyIndex = oss.operationLog.indexOf('copy:$key');
        final deleteIndex = oss.operationLog.indexWhere((entry) =>
            entry.startsWith('deleteMany:') &&
            (entry == 'deleteMany:$key' ||
                entry.startsWith('deleteMany:$key,') ||
                entry.contains(',$key') ||
                entry.endsWith(',$key')));
        expect(copyIndex, greaterThanOrEqualTo(0), reason: key);
        expect(deleteIndex, greaterThan(copyIndex), reason: key);
      }
    });

    test('流式执行：列举未完成时进度总数随分页递增', () async {
      final oss = _FakeOssClient()
        ..objects.addAll(<String>{
          'shared/src/',
          'shared/src/a.txt',
          'shared/src/b.txt',
          'shared/src/c.txt',
          'shared/src/d.txt',
          'shared/src/e.txt',
        })
        ..listPageSize = 2;
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);
      final snapshots = <MoveProgress>[];
      move.controller.moveStateListenable.addListener(() {
        final value = move.controller.moveStateListenable.value;
        if (value != null) snapshots.add(value);
      });

      await move.controller
          .moveItems(<FileItem>[dir('shared/src/')], 'shared/dst/');

      final counting = snapshots.where((s) => s.isCounting).toList();
      expect(counting, isNotEmpty);
      // 列举未完成时总数尚未到 6，且随每页结果递增。
      expect(counting.first.total, lessThan(6));
      expect(counting.map((s) => s.total).toSet().length, greaterThan(1));
      final last = snapshots.last;
      expect(last.isCounting, isFalse);
      expect(last.processed, 6);
      expect(last.total, 6);
    });

    test('续迁中断批次：一页内双侧重复副本幂等收敛', () async {
      final entry = MoveTaskEntry(
        id: 'task-1',
        sourcePrefixes: <String>['shared/src/'],
        targetPrefix: 'shared/dst/',
        createdAt: DateTime(2026, 1, 1),
      );
      final oss = _FakeOssClient()
        ..objects.addAll(<String>{
          'shared/.moves/task-1/manifest.json',
          'shared/src/',
          'shared/src/x.txt',
          'shared/dst/src/',
          'shared/dst/src/x.txt',
          'shared/dst/src/moved.txt',
        })
        ..sizes['shared/src/x.txt'] = 5
        ..sizes['shared/dst/src/x.txt'] = 5
        ..sizes['shared/dst/src/moved.txt'] = 7
        ..textContent['shared/.moves/task-1/manifest.json'] = entry.encode();
      final move = await _moveStack(oss: oss);
      addTearDown(move.dispose);

      final pending = await move.controller.listPendingMoves();
      expect(pending, hasLength(1));
      final summary = await move.controller.resumePendingMove(pending.first);

      expect(summary.hasFailures, isFalse);
      expect(oss.objects, <String>{
        'shared/dst/src/',
        'shared/dst/src/x.txt',
        'shared/dst/src/moved.txt',
      });
      expect(oss.manifestKeys, isEmpty);
    });
  });
}

String _fileName(String path) {
  final normalized = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

typedef _MoveStack = ({
  MoveController controller,
  _FakeOssClient oss,
  void Function() dispose,
});

/// 直测夹层：按生产装配顺序构建 Session → Workspace → MoveController，
/// 不经过 AppServices 门面。
Future<_MoveStack> _moveStack({_FakeOssClient? oss}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final client = oss ?? _FakeOssClient();
  final sessionController = SessionController(
    sessionRepository: _FakeSessionRepository(_session()),
    ossClient: client,
  );
  await sessionController.bootstrap();
  final workspaceController = WorkspaceController(
    sessionController: sessionController,
    ossClient: client,
  );
  final controller = MoveController(
    sessionController: sessionController,
    workspaceController: workspaceController,
    ossClient: client,
  );

  void dispose() {
    controller.dispose();
    workspaceController.dispose();
    sessionController.dispose();
  }

  return (controller: controller, oss: client, dispose: dispose);
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
