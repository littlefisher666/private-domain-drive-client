import 'package:flutter/foundation.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/network/api_client.dart';
import '../domain/user_session.dart';
import 'secure_session_store.dart';

abstract class SessionRepository {
  Future<UserSession?> restore();
  Future<UserSession> login(
      {required String account, required String password});
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
    required String appVersion,
  })  : _store = store,
        _apiClient = apiClient,
        _appVersion = appVersion;

  final SecureSessionStore _store;
  final ApiClient _apiClient;
  final String _appVersion;

  @override
  Future<UserSession?> restore() async {
    // OSS 访问密钥仅在会话内存中持有、不落盘；冷启动必须重新登录换取密钥。
    // 这里仅清理旧版本可能持久化过的会话数据。
    try {
      await _store.clear();
    } catch (_) {
      // 清理失败不应阻断登录流程。
    }
    return null;
  }

  @override
  Future<UserSession> login({
    required String account,
    required String password,
  }) async {
    final trimmed = account.trim();
    try {
      return await _apiClient.bootstrapSession(
        account: trimmed,
        password: password,
        platform: _platformName(),
        appVersion: _appVersion,
      );
    } on AppError {
      rethrow;
    } catch (error) {
      throw AppError(error.toString(), code: 'LOGIN_FAILED');
    }
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
    return session.copyWith(mustResetPassword: false);
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
