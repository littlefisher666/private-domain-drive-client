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
    try {
      final session = await _store.read();
      final valid = session != null &&
          session.isRemote &&
          session.ossConfig != null &&
          session.credentials?.isValid == true;
      if (!valid) {
        // 数据不完整或属于旧版本格式，清除后走重新登录。
        await _store.clear();
        return null;
      }
      return session;
    } catch (_) {
      // 安全存储读取失败时退回登录页，不清理可能仍有效的数据。
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
      try {
        await _store.write(session);
      } catch (_) {
        // 持久化失败不影响本次登录，仅下次冷启动需重新登录。
      }
      return session;
    } on AppError {
      rethrow;
    } catch (error) {
      debugPrint('[login] unexpected error: $error');
      throw AppError('登录失败，请稍后重试', code: 'LOGIN_FAILED');
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
    final updated = session.copyWith(mustResetPassword: false);
    try {
      await _store.write(updated);
    } catch (_) {
      // 持久化失败不影响本次改密，仅下次冷启动需重新登录。
    }
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
      throw AppError('用户名或密码错误', code: 'UNAUTHORIZED');
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
      throw AppError('当前密码错误', code: 'UNAUTHORIZED');
    }
    _session = session.copyWith(mustResetPassword: false);
    return _session!;
  }

  @override
  Future<void> logout() async {
    _session = null;
  }
}
