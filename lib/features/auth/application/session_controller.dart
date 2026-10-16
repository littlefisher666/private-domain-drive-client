import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/errors/app_error.dart';
import '../../workspace/infrastructure/oss_client.dart';
import '../domain/login_result.dart';
import '../domain/user_session.dart';
import '../infrastructure/saved_credentials_store.dart';
import '../infrastructure/session_repository.dart';

/// 会话/认证域控制器：登录、登出、启动会话恢复、修改密码与凭证失效处理。
class SessionController extends ChangeNotifier {
  SessionController({
    required SessionRepository sessionRepository,
    required OssClient ossClient,
    SavedCredentialsStore? savedCredentialsStore,
  })  : _sessionRepository = sessionRepository,
        _ossClient = ossClient,
        _savedCredentialsStore = savedCredentialsStore ?? SavedCredentialsStore();

  final SessionRepository _sessionRepository;
  final OssClient _ossClient;
  final SavedCredentialsStore _savedCredentialsStore;

  /// 会话清除前的跨域清理（传输取消、冲突批次决策清空），装配层注入。
  VoidCallback? beforeSessionCleared;

  /// 会话变更后的跨域复位（工作区路径/选择/统计重置、分享清空），装配层注入。
  VoidCallback? onSessionChanged;

  UserSession? _session;
  bool _bootstrapped = false;

  UserSession? get session => _session;
  bool get isLoggedIn => _session != null;
  bool get bootstrapped => _bootstrapped;

  /// 启动恢复会话：读取持久化会话并配置 OSS 客户端；失败时保持未登录。
  Future<void> bootstrap() async {
    try {
      final restored = await _sessionRepository.restore();
      if (restored != null && restored.isRemote) {
        _session = restored;
        await _ossClient.configureSession(restored);
        onSessionChanged?.call();
      }
    } catch (_) {
      // Keep app usable even if secure storage restore fails.
    }
    _bootstrapped = true;
    notifyListeners();
  }

  Future<LoginResult> login({
    required String account,
    required String password,
  }) async {
    try {
      final session = await _sessionRepository.login(
        account: account,
        password: password,
      );
      _session = session;
      if (session.isRemote) {
        await _ossClient.configureSession(session);
      }
      await _rememberCredentials(account: account.trim(), password: password);
      onSessionChanged?.call();
      notifyListeners();
      return LoginResult.success(session);
    } on AppError catch (error) {
      return LoginResult.failure(error.message);
    } catch (error) {
      debugPrint('[login] unexpected error: $error');
      return const LoginResult.failure('登录失败，请稍后重试');
    }
  }

  /// 供登录页预填最近一次成功登录的用户名与密码。
  Future<SavedCredentials?> readSavedCredentials() {
    return _savedCredentialsStore.read();
  }

  Future<void> _rememberCredentials({
    required String account,
    required String password,
  }) async {
    try {
      await _savedCredentialsStore.write(
        SavedCredentials(account: account, password: password),
      );
    } catch (_) {
      // 凭据记忆失败不应影响登录流程。
    }
  }

  Future<void> logout() async {
    beforeSessionCleared?.call();
    await _ossClient.clearConfiguration();
    await _sessionRepository.logout();
    _session = null;
    onSessionChanged?.call();
    notifyListeners();
  }

  Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final session = _session;
    if (session == null) {
      return '请先登录';
    }
    if (newPassword.length < 8) {
      return '新密码至少需要 8 个字符';
    }
    try {
      _session = await _sessionRepository.changePassword(
        session: session,
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      await _rememberCredentials(
        account: session.account,
        password: newPassword,
      );
      notifyListeners();
      return null;
    } on AppError catch (error) {
      return error.message;
    } catch (error) {
      debugPrint('[changePassword] unexpected error: $error');
      return '修改失败，请稍后重试';
    }
  }

  /// 校验当前会话可用。访问密钥为登录下发的长期密钥，
  /// 无需刷新；失效时由 [handleCredentialExpired] 引导重新登录。
  Future<void> ensureSessionReady() async {
    final session = _session;
    if (session == null || !session.isRemote) {
      return;
    }
    if (session.credentials?.isValid != true) {
      throw AppError('会话缺少 OSS 凭证，请重新登录', code: 'REMOTE_SESSION_REQUIRED');
    }
    await _ossClient.configureSession(session);
  }

  /// OSS 鉴权失败（密钥被撤销等）时清除会话，由外层引导用户重新登录。
  void handleCredentialExpired() {
    if (_session == null) {
      return;
    }
    unawaited(logout());
  }

  /// 取回当前可用会话；未登录或缺少凭据时抛出统一错误。
  UserSession requireSession() {
    final session = _session;
    if (session == null || !session.isRemote || session.credentials == null) {
      throw AppError('请先登录', code: 'REMOTE_SESSION_REQUIRED');
    }
    return session;
  }
}
