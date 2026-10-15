import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:private_domain_drive_client/core/errors/app_error.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/workspace/domain/file_item.dart';
import 'package:private_domain_drive_client/features/workspace/domain/recycle_bin_entry.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/features/workspace/presentation/recycle_bin_page.dart';
import 'package:private_domain_drive_client/shared/state/app_controller.dart';
import 'package:private_domain_drive_client/shared/state/app_scope.dart';

void main() {
  group('回收站逐项条目', () {
    test('多选删除按顶层条目建立独立回收条目', () async {
      final oss = _TrashOssClient()
        ..objectKeysByPath['shared/目录/'] = <String>['shared/目录/a.txt']
        ..objectKeysByPath['shared/图片/'] = <String>['shared/图片/pic.jpg'];
      final controller = await _controller(oss: oss);
      addTearDown(controller.dispose);

      final preview = await controller.prepareBatchDelete(const <FileItem>[
        FileItem(path: 'shared/目录/', name: '目录', isDirectory: true),
        FileItem(path: 'shared/图片/', name: '图片', isDirectory: true),
        FileItem(path: 'shared/说明.md', name: '说明.md', isDirectory: false),
      ]);
      final result = await controller.deleteBatch(preview);

      expect(result.failedPaths, isEmpty);
      final entries = await controller.listRecycleBin();
      expect(entries, hasLength(3));
      expect(
        entries.map((entry) => entry.name).toSet(),
        <String>{'目录', '图片', '说明.md'},
      );
      for (final entry in entries) {
        expect(entry.objects, isNotEmpty);
        for (final target in entry.objects.values) {
          expect(target, startsWith('shared/.trash/${entry.id}/payload/'));
        }
      }
      expect(oss.deleted, containsAll(<String>[
        'shared/目录/',
        'shared/目录/a.txt',
        'shared/图片/',
        'shared/图片/pic.jpg',
        'shared/说明.md',
      ]));
    });

    test('同名文件先后删除时后者追加时间戳', () async {
      final oss = _TrashOssClient();
      final controller = await _controller(oss: oss);
      addTearDown(controller.dispose);
      const item = FileItem(
        path: 'shared/报告.pdf',
        name: '报告.pdf',
        isDirectory: false,
      );

      await controller.deleteItem(item);
      await controller.deleteItem(item);

      final entries = await controller.listRecycleBin();
      expect(entries, hasLength(2));
      expect(
        entries.map((entry) => entry.name).toSet(),
        containsAll(<Matcher>[
          equals('报告.pdf'),
          matches(r'^报告_\d{8}_\d{6}\.pdf$'),
        ]),
      );
    });

    test('同批同名文件各自成条目且展示名不冲突', () async {
      final oss = _TrashOssClient();
      final controller = await _controller(oss: oss);
      addTearDown(controller.dispose);

      final preview = await controller.prepareBatchDelete(const <FileItem>[
        FileItem(path: 'shared/x/a.txt', name: 'a.txt', isDirectory: false),
        FileItem(path: 'shared/y/a.txt', name: 'a.txt', isDirectory: false),
      ]);
      await controller.deleteBatch(preview);

      final entries = await controller.listRecycleBin();
      expect(entries, hasLength(2));
      expect(entries.map((entry) => entry.name), contains('a.txt'));
      final renamed = entries
          .map((entry) => entry.name)
          .where((name) => name != 'a.txt')
          .toList(growable: false);
      expect(renamed, hasLength(1));
      expect(renamed.single, matches(r'^a_\d{8}_\d{6}(_\d+)?\.txt$'));
    });

    test('同名文件夹删除时展示名追加时间戳', () async {
      final oss = _TrashOssClient()
        ..objectKeysByPath['shared/资料/'] = <String>['shared/资料/'];
      final controller = await _controller(oss: oss);
      addTearDown(controller.dispose);
      const item = FileItem(
        path: 'shared/资料/',
        name: '资料',
        isDirectory: true,
      );

      await controller.deleteItem(item);
      await controller.deleteItem(item);

      final entries = await controller.listRecycleBin();
      expect(entries, hasLength(2));
      expect(
        entries.map((entry) => entry.name).toSet(),
        containsAll(<Matcher>[
          equals('资料'),
          matches(r'^资料_\d{8}_\d{6}(_\d+)?$'),
        ]),
      );
    });

    test('删除文件夹仍建立单个条目并递归收录全部对象', () async {
      final oss = _TrashOssClient()
        ..objectKeysByPath['shared/目录/'] = <String>[
          'shared/目录/a.txt',
          'shared/目录/子目录/',
        ];
      final controller = await _controller(oss: oss);
      addTearDown(controller.dispose);

      await controller.deleteItem(
        const FileItem(path: 'shared/目录/', name: '目录', isDirectory: true),
      );

      final entries = await controller.listRecycleBin();
      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry.name, '目录');
      expect(entry.isDirectory, isTrue);
      expect(entry.originalPath, 'shared/目录/');
      expect(entry.objects.keys, containsAll(<String>[
        'shared/目录/',
        'shared/目录/a.txt',
        'shared/目录/子目录/',
      ]));
      expect(oss.copies, hasLength(3));
    });

    test('嵌套选中的子文件由父目录条目统一归属，不重复拷贝', () async {
      final oss = _TrashOssClient()
        ..objectKeysByPath['shared/目录/'] = <String>['shared/目录/a.txt'];
      final controller = await _controller(oss: oss);
      addTearDown(controller.dispose);

      final preview = await controller.prepareBatchDelete(const <FileItem>[
        FileItem(path: 'shared/目录/', name: '目录', isDirectory: true),
        FileItem(path: 'shared/目录/a.txt', name: 'a.txt', isDirectory: false),
      ]);
      await controller.deleteBatch(preview);

      final entries = await controller.listRecycleBin();
      expect(entries, hasLength(1));
      expect(entries.single.name, '目录');
      expect(oss.copies, hasLength(2));
      expect(
        oss.copies.map((copy) => copy.$1).toSet(),
        <String>{'shared/目录/', 'shared/目录/a.txt'},
      );
    });

    test('拷贝失败的对象不建条目也不删除源对象', () async {
      final oss = _TrashOssClient()..copyFailures = <String>{'shared/b.txt'};
      final controller = await _controller(oss: oss);
      addTearDown(controller.dispose);

      final preview = await controller.prepareBatchDelete(const <FileItem>[
        FileItem(path: 'shared/a.txt', name: 'a.txt', isDirectory: false),
        FileItem(path: 'shared/b.txt', name: 'b.txt', isDirectory: false),
      ]);
      final result = await controller.deleteBatch(preview);

      expect(result.failedPaths, <String>['shared/b.txt']);
      expect(oss.deleted, contains('shared/a.txt'));
      expect(oss.deleted, isNot(contains('shared/b.txt')));
      final entries = await controller.listRecycleBin();
      expect(entries, hasLength(1));
      expect(entries.single.name, 'a.txt');
    });
  });

  group('RecycleBinPage', () {
    testWidgets('回收站根层平铺条目并可进入条目内部结构', (tester) async {
      final oss = _TrashOssClient();
      final controller = await _controller(oss: oss);
      addTearDown(controller.dispose);
      await _seedManifest(oss, controller, RecycleBinEntry(
        id: 'entry-1',
        name: '资料',
        originalPath: 'shared/资料/',
        isDirectory: true,
        deletedAt: DateTime(2026, 10, 15),
        objects: const <String, String>{
          'shared/资料/': 'shared/.trash/entry-1/payload/资料/',
          'shared/资料/a.txt': 'shared/.trash/entry-1/payload/资料/a.txt',
        },
      ));
      await _seedManifest(oss, controller, RecycleBinEntry(
        id: 'entry-2',
        name: '报告.pdf',
        originalPath: 'shared/报告.pdf',
        isDirectory: false,
        deletedAt: DateTime(2026, 10, 14),
        objects: const <String, String>{
          'shared/报告.pdf': 'shared/.trash/entry-2/payload/报告.pdf',
        },
      ));

      await tester.pumpWidget(
        AppScope(
          controller: controller,
          child: const MaterialApp(home: RecycleBinPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('资料'), findsOneWidget);
      expect(find.text('报告.pdf'), findsOneWidget);

      await tester.tap(find.text('资料'));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('报告.pdf'), findsNothing);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('资料'), findsOneWidget);
      expect(find.text('报告.pdf'), findsOneWidget);
    });
  });
}

Future<void> _seedManifest(
  _TrashOssClient oss,
  AppController controller,
  RecycleBinEntry entry,
) async {
  await oss.uploadText(
    'shared/.trash/${entry.id}/manifest.json',
    entry.encode(),
    controller.session!,
  );
}

Future<AppController> _controller({_TrashOssClient? oss}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final controller = AppController(
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

/// 模拟回收站对象存储：manifest 通过 uploadText 落地，
/// listPrefixes 与 download 据此返回条目列表与清单内容。
class _TrashOssClient extends OssClient {
  final Map<String, List<String>> objectKeysByPath = <String, List<String>>{};
  final Map<String, String> manifests = <String, String>{};
  final List<String> entryRoots = <String>[];
  final List<(String, String)> copies = <(String, String)>[];
  final List<String> deleted = <String>[];
  Set<String> copyFailures = <String>{};

  @override
  Future<void> configureSession(UserSession session) async {}

  @override
  Future<void> clearConfiguration() async {}

  @override
  Future<List<String>> listAllObjectKeys(
    String path,
    UserSession session,
  ) async =>
      objectKeysByPath[path] ?? const <String>[];

  @override
  Future<void> copy(String from, String to, UserSession session) async {
    if (copyFailures.contains(from)) {
      throw AppError('模拟拷贝失败', code: 'OSS_COPY_FAILED');
    }
    copies.add((from, to));
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
  Future<void> uploadText(
    String path,
    String content,
    UserSession session,
  ) async {
    manifests[path] = content;
    entryRoots.add(path.substring(0, path.length - 'manifest.json'.length));
  }

  @override
  Future<List<String>> listPrefixes(
    String prefix,
    UserSession session,
  ) async =>
      <String>[
        for (final root in entryRoots)
          if (root.startsWith(prefix)) root,
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
}
