import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/core/errors/app_error.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/workspace/domain/recycle_bin_entry.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/features/workspace/presentation/recycle_bin_page.dart';
import 'package:private_domain_drive_client/features/workspace/presentation/widgets/recycle_bin_batch_bar.dart';
import 'package:private_domain_drive_client/shared/state/app_scope.dart';
import 'package:private_domain_drive_client/shared/state/app_services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AppServices> pumpPage(WidgetTester tester, _TrashOssClient oss) async {
    final controller = await _controller(oss: oss);
    await _seed(oss, controller);
    await tester.pumpWidget(
      AppScope(
        services: controller,
        child: const MaterialApp(home: RecycleBinPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    return controller;
  }

  testWidgets('移动端长按进入多选并可点选与全选', (tester) async {
    final controller = await pumpPage(tester, _TrashOssClient());
    addTearDown(controller.dispose);

    await tester.longPress(find.text('报告.pdf'));
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);

    await tester.tap(find.text('说明.md'));
    await tester.pump();
    expect(find.text('已选 2 项'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byType(RecycleBinBatchBar),
      matching: find.byType(Checkbox),
    ));
    await tester.pump();
    expect(find.text('已选 3 项'), findsOneWidget);

    await tester.tap(find.text('退出多选'));
    await tester.pump();
    expect(find.byType(RecycleBinBatchBar), findsNothing);
  });

  testWidgets('进入条目内部后不提供多选', (tester) async {
    final controller = await pumpPage(tester, _TrashOssClient());
    addTearDown(controller.dispose);

    await tester.tap(find.text('资料'));
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(RecycleBinBatchBar), findsNothing);
    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();

    expect(find.text('已选 1 项'), findsNothing);
    expect(find.text('恢复'), findsOneWidget);
  });

  testWidgets('批量立即删除取消后不做任何变更', (tester) async {
    final oss = _TrashOssClient();
    final controller = await pumpPage(tester, oss);
    addTearDown(controller.dispose);

    await tester.longPress(find.text('报告.pdf'));
    await tester.pump();
    await tester.tap(find.text('说明.md'));
    await tester.pump();

    await tester.tap(find.text('立即删除'));
    await tester.pumpAndSettle();
    expect(find.text('立即删除选中的 2 个条目？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(oss.deleted, isEmpty);
    expect(find.text('报告.pdf'), findsOneWidget);
    expect(find.text('说明.md'), findsOneWidget);
  });

  testWidgets('清空回收站需确认并删除全部条目', (tester) async {
    final oss = _TrashOssClient();
    final controller = await pumpPage(tester, oss);
    addTearDown(controller.dispose);

    await tester.tap(find.text('清空回收站'));
    await tester.pumpAndSettle();
    expect(find.text('清空回收站？'), findsOneWidget);
    expect(find.textContaining('全部 3 个条目'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(find.text('回收站为空'), findsOneWidget);
    expect(
      oss.deleted,
      containsAll(<String>[
        'shared/.trash/entry-1/manifest.json',
        'shared/.trash/entry-2/manifest.json',
        'shared/.trash/entry-3/manifest.json',
      ]),
    );
  });

  testWidgets('清空时部分失败保留失败条目并报告数量', (tester) async {
    final oss = _TrashOssClient()
      ..deleteFailures.add('shared/.trash/entry-2/manifest.json');
    final controller = await pumpPage(tester, oss);
    addTearDown(controller.dispose);

    await tester.tap(find.text('清空回收站'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 个失败'), findsOneWidget);
    expect(find.text('报告.pdf'), findsOneWidget);
    expect(find.text('资料'), findsNothing);
    expect(find.text('说明.md'), findsNothing);
  });
}

Future<void> _seed(_TrashOssClient oss, AppServices controller) async {
  final session = controller.sessionController.session!;
  final entries = <RecycleBinEntry>[
    RecycleBinEntry(
      id: 'entry-1',
      name: '资料',
      originalPath: 'shared/资料/',
      isDirectory: true,
      deletedAt: DateTime(2026, 10, 15),
      objects: const <String, String>{
        'shared/资料/': 'shared/.trash/entry-1/payload/资料/',
        'shared/资料/a.txt': 'shared/.trash/entry-1/payload/资料/a.txt',
      },
    ),
    RecycleBinEntry(
      id: 'entry-2',
      name: '报告.pdf',
      originalPath: 'shared/报告.pdf',
      isDirectory: false,
      deletedAt: DateTime(2026, 10, 14),
      objects: const <String, String>{
        'shared/报告.pdf': 'shared/.trash/entry-2/payload/报告.pdf',
      },
    ),
    RecycleBinEntry(
      id: 'entry-3',
      name: '说明.md',
      originalPath: 'shared/说明.md',
      isDirectory: false,
      deletedAt: DateTime(2026, 10, 13),
      objects: const <String, String>{
        'shared/说明.md': 'shared/.trash/entry-3/payload/说明.md',
      },
    ),
  ];
  for (final entry in entries) {
    await oss.uploadText(
      'shared/.trash/${entry.id}/manifest.json',
      entry.encode(),
      session,
    );
  }
}

Future<AppServices> _controller({_TrashOssClient? oss}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final controller = AppServices(
    sessionRepository: _FakeSessionRepository(_session()),
    ossClient: oss ?? _TrashOssClient(),
  );
  await controller.bootstrap();
  return controller;
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

class _TrashOssClient extends OssClient {
  final Map<String, String> manifests = <String, String>{};
  final List<String> deleted = <String>[];
  final Set<String> deleteFailures = <String>{};

  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<void> clearConfiguration() async {}

  @override
  Future<void> uploadText(
    String path,
    String content,
    UserSession session,
  ) async {
    manifests[path] = content;
  }

  @override
  Future<List<String>> listPrefixes(
    String prefix,
    UserSession session,
  ) async =>
      <String>[
        for (final path in manifests.keys)
          if (path.startsWith(prefix))
            path.substring(0, path.length - 'manifest.json'.length),
      ];

  @override
  Future<List<int>> download(
    String path,
    UserSession session, {
    int? maxBytes,
  }) async {
    final content = manifests[path];
    if (content == null) {
      throw AppError('对象不存在', code: 'OSS_NOT_FOUND');
    }
    return utf8.encode(content);
  }

  @override
  Future<BatchDeleteResult> deleteMany(
    Iterable<String> paths,
    UserSession session,
  ) async {
    final deletedPaths = <String>[];
    final failedPaths = <String>[];
    for (final path in paths) {
      if (deleteFailures.contains(path)) {
        failedPaths.add(path);
        continue;
      }
      deleted.add(path);
      deletedPaths.add(path);
      manifests.remove(path);
    }
    return BatchDeleteResult(
      deletedPaths: deletedPaths,
      failedPaths: failedPaths,
    );
  }
}
