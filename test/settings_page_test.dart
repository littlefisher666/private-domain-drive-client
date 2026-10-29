import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/app/router/route_names.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/settings/presentation/settings_page.dart';
import 'package:private_domain_drive_client/features/workspace/infrastructure/oss_client.dart';
import 'package:private_domain_drive_client/shared/cache/cache_manager.dart';
import 'package:private_domain_drive_client/shared/cache/local_cache_store.dart';
import 'package:private_domain_drive_client/shared/state/app_scope.dart';
import 'package:private_domain_drive_client/shared/state/app_services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeOssClient extends OssClient {
  @override
  Future<void> clearConfiguration() async {}
}

class _MemoryCacheStore implements LocalCacheStore {
  _MemoryCacheStore(this.bytes);

  int bytes;

  @override
  Future<void> clear() async {
    bytes = 0;
  }

  @override
  Future<int> sizeBytes() async => bytes;
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  late CacheManager cacheManager;
  late _MemoryCacheStore imageCache;

  setUp(() {
    imageCache = _MemoryCacheStore(1024);
    cacheManager = CacheManager(
      imageCache: imageCache,
      documentCache: _MemoryCacheStore(256),
      shareCacheStore: _MemoryCacheStore(256),
      originalCacheStore: () => _MemoryCacheStore(0),
    );
  });

  Future<AppServices> pumpSettings(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final services = AppServices(
      sessionRepository: MemorySessionRepository(),
      ossClient: _FakeOssClient(),
      cacheManager: cacheManager,
    );
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          routes: <String, WidgetBuilder>{
            RouteNames.login: (_) =>
                const Scaffold(body: Center(child: Text('登录页'))),
          },
          home: const SettingsPage(embedded: true, desktopChrome: true),
        ),
      ),
    );
    await settle(tester);
    return services;
  }

  Future<void> scrollToLogout(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '退出登录'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }

  testWidgets('设置页展示缓存占用与清理入口', (tester) async {
    await pumpSettings(tester);

    expect(find.text('缓存占用'), findsOneWidget);
    expect(find.text('1.5 KB'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '清理缓存'), findsOneWidget);
  });

  testWidgets('取消清理缓存不删除也不提示', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.widgetWithText(TextButton, '清理缓存'));
    await settle(tester);
    expect(find.text('清理缓存？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await settle(tester);

    expect(find.text('清理缓存？'), findsNothing);
    expect(find.textContaining('已释放'), findsNothing);
    expect(find.text('1.5 KB'), findsOneWidget);
    expect(imageCache.bytes, 1024);
  });

  testWidgets('确认清理缓存后刷新占用并提示释放空间', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.widgetWithText(TextButton, '清理缓存'));
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '清理'),
      ),
    );
    await settle(tester);

    expect(find.text('已释放 1.5 KB'), findsOneWidget);
    expect(find.text('0 B'), findsOneWidget);
    expect(imageCache.bytes, 0);
  });

  testWidgets('取消退出登录保持当前页面', (tester) async {
    final services = await pumpSettings(tester);
    await scrollToLogout(tester);

    await tester.tap(find.widgetWithText(FilledButton, '退出登录'));
    await settle(tester);
    expect(find.text('退出登录？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await settle(tester);

    expect(find.text('退出登录？'), findsNothing);
    expect(find.text('缓存占用'), findsOneWidget);
    expect(services.sessionController.session, isNull);
  });

  testWidgets('确认退出登录后返回登录页', (tester) async {
    await pumpSettings(tester);
    await scrollToLogout(tester);

    await tester.tap(find.widgetWithText(FilledButton, '退出登录'));
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '退出登录'),
      ),
    );
    await settle(tester);

    expect(find.text('登录页'), findsOneWidget);
  });
}
