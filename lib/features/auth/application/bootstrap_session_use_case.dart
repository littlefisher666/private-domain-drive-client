import '../domain/user_session.dart';
import '../infrastructure/session_repository.dart';

class BootstrapSessionUseCase {
  const BootstrapSessionUseCase(this._repository);

  final SessionRepository _repository;

  Future<UserSession?> execute() => _repository.restore();
}

class LoginUseCase {
  const LoginUseCase(this._repository);

  final SessionRepository _repository;

  Future<UserSession> execute({
    required String account,
    required String password,
  }) {
    return _repository.login(account: account, password: password);
  }
}

class LogoutUseCase {
  const LogoutUseCase(this._repository);

  final SessionRepository _repository;

  Future<void> execute() => _repository.logout();
}
