import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/auth/domain/user_session.dart';
import 'package:private_domain_drive_client/features/auth/infrastructure/session_repository.dart';
import 'package:private_domain_drive_client/features/file_share/infrastructure/share_cache_store.dart';
import 'package:private_domain_drive_client/shared/state/app_services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('App 启动时异步调度一次分享缓存清理', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final cacheStore = _RecordingShareCacheStore();
    final services = AppServices(
      sessionRepository: _FakeSessionRepository(_session()),
      shareCacheStore: cacheStore,
    );

    await services.bootstrap();
    await pumpEventQueue();

    expect(cacheStore.cleanCalls, 1);
    services.dispose();
  });
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

class _RecordingShareCacheStore extends ShareCacheStore {
  int cleanCalls = 0;

  @override
  Future<int> clean({
    Set<String> keepPaths = const <String>{},
    DateTime? now,
  }) async {
    cleanCalls++;
    return 0;
  }
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
