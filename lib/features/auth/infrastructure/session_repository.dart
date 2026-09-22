import 'package:flutter/foundation.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/network/api_client.dart';
import '../domain/user_session.dart';
import 'aliyun_sts_client.dart';
import 'secure_session_store.dart';

abstract class SessionRepository {
  Future<UserSession?> restore();
  Future<UserSession> login(
      {required String account, required String password});
  Future<UserSession> refreshCredentials(UserSession session);
  Future<UserSession> changePassword({
    required UserSession session,
    required String currentPassword,
    required String newPassword,
  });
  Future<void> logout();
}

class PersistentSessionRepository implements SessionRepository {
  PersistentSessionRepository({
    required SecureSessionStore store,
    required ApiClient apiClient,
    required AliyunStsClient stsClient,
    required String appVersion,
  })  : _store = store,
        _apiClient = apiClient,
        _stsClient = stsClient,
        _appVersion = appVersion;

  final SecureSessionStore _store;
  final ApiClient _apiClient;
  final AliyunStsClient _stsClient;
  final String _appVersion;

  @override
  Future<UserSession?> restore() async {
    final cached = await _store.read();
    if (cached == null) {
      return null;
    }

    // 旧版本可能保存过本地演示会话，生产环境不得恢复该身份。
    if (!cached.isRemote) {
      await _store.clear();
      return null;
    }

    final credentials = cached.credentials;
    if (credentials != null &&
        credentials.isValid(skew: AppConstants.stsRefreshSkew)) {
      return cached;
    }

    try {
      return await refreshCredentials(cached);
    } catch (_) {
      // Keep identity for next login decision only if broker is missing;
      // expired remote session without refresh should re-login.
      await _store.clear();
      return null;
    }
  }

  @override
  Future<UserSession> login({
    required String account,
    required String password,
  }) async {
    final trimmed = account.trim();
    try {
      final session = await _apiClient.bootstrapSession(
        account: trimmed,
        password: password,
        platform: _platformName(),
        appVersion: _appVersion,
      );
      await _store.write(session);
      return session;
    } on AppError {
      rethrow;
    } catch (error) {
      throw AppError(error.toString(), code: 'LOGIN_FAILED');
    }
  }

  @override
  Future<UserSession> refreshCredentials(UserSession session) async {
    final broker = session.stsBroker;
    if (broker == null) {
      throw AppError('缺少本地 STS 换票凭证，请重新登录', code: 'STS_BROKER_MISSING');
    }

    final credentials = await _stsClient.assumeRole(broker);
    final refreshed = session.copyWith(credentials: credentials);
    await _store.write(refreshed);
    return refreshed;
  }

  @override
  Future<UserSession> changePassword({
    required UserSession session,
    required String currentPassword,
    required String newPassword,
  }) async {
    await _apiClient.changePassword(
      account: session.account,
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
    final updated = session.copyWith(mustResetPassword: false);
    await _store.write(updated);
    return updated;
  }

  @override
  Future<void> logout() async {
    await _store.clear();
  }

  String _platformName() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.android:
        return 'android';
      default:
        return defaultTargetPlatform.name;
    }
  }
}

/// Test-only in-memory repository.
class MemorySessionRepository implements SessionRepository {
  UserSession? _session;

  @override
  Future<UserSession?> restore() async => _session;

  @override
  Future<UserSession> login({
    required String account,
    required String password,
  }) async {
    const users = <String, ({String password, String displayName})>{
      'admin': (password: '123456', displayName: 'admin'),
      'member': (password: '123456', displayName: 'member'),
    };
    final key = account.trim();
    final user = users[key];
    if (user == null || user.password != password) {
      throw AppError('账号或口令错误', code: 'UNAUTHORIZED');
    }
    _session = UserSession(
      userId: user.displayName,
      account: user.displayName,
      displayName: user.displayName,
      role: 'member',
      capabilities: const Capabilities.standard(),
      rootPrefix: 'shared/',
      authMode: SessionAuthMode.localMock,
    );
    return _session!;
  }

  @override
  Future<UserSession> refreshCredentials(UserSession session) async => session;

  @override
  Future<UserSession> changePassword({
    required UserSession session,
    required String currentPassword,
    required String newPassword,
  }) async {
    if (currentPassword != '123456' || newPassword.length < 8) {
      throw AppError('账号或当前口令错误', code: 'UNAUTHORIZED');
    }
    _session = session.copyWith(mustResetPassword: false);
    return _session!;
  }

  @override
  Future<void> logout() async {
    _session = null;
  }
}
