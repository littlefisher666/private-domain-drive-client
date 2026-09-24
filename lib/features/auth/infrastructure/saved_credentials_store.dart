import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SavedCredentials {
  const SavedCredentials({required this.account, required this.password});

  final String account;
  final String password;
}

/// 凭据存储后端抽象。生产环境按平台选择实现，测试注入内存实现，
/// 避免 testWidgets 中未 mock 的平台通道调用永不返回导致套件挂起。
abstract interface class CredentialsStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

/// 生产环境后端：macOS 用 SharedPreferences，其他平台用安全存储。
class PlatformCredentialsStorage implements CredentialsStorage {
  PlatformCredentialsStorage({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secureStorage;

  @override
  Future<String?> read(String key) async {
    if (Platform.isMacOS) {
      final preferences = await SharedPreferences.getInstance();
      return preferences.getString(key);
    }
    return _secureStorage.read(key: key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (Platform.isMacOS) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(key, value);
      return;
    }
    await _secureStorage.write(key: key, value: value);
  }
}

/// 测试与纯内存场景使用的后端。
class InMemoryCredentialsStorage implements CredentialsStorage {
  InMemoryCredentialsStorage({Map<String, String> initialValues = const {}})
      : _values = Map<String, String>.of(initialValues);

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}

/// 记住最近一次成功登录的用户名与密码，供下次打开登录页预填。
/// 改密成功后同步更新，避免预填过期密码。
class SavedCredentialsStore {
  SavedCredentialsStore({CredentialsStorage? storage})
      : _storage = storage ?? PlatformCredentialsStorage();

  static const _storageKey = 'pdd.saved_credentials.v1';

  final CredentialsStorage _storage;

  Future<SavedCredentials?> read() async {
    try {
      final raw = await _storage.read(_storageKey);
      if (raw == null || raw.isEmpty) {
        return null;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final account = decoded['account'];
      final password = decoded['password'];
      if (account is! String || password is! String) {
        return null;
      }
      return SavedCredentials(account: account, password: password);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(SavedCredentials credentials) async {
    await _storage.write(
      _storageKey,
      jsonEncode(<String, String>{
        'account': credentials.account,
        'password': credentials.password,
      }),
    );
  }
}
