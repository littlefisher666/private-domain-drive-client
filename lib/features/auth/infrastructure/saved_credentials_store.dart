import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SavedCredentials {
  const SavedCredentials({required this.account, required this.password});

  final String account;
  final String password;
}

/// 记住最近一次成功登录的用户名与密码，供下次打开登录页预填。
/// 改密成功后同步更新，避免预填过期密码。
class SavedCredentialsStore {
  SavedCredentialsStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _storageKey = 'pdd.saved_credentials.v1';

  final FlutterSecureStorage _storage;

  Future<SavedCredentials?> read() async {
    try {
      final raw = await _readRaw();
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
    await _writeRaw(jsonEncode(<String, String>{
      'account': credentials.account,
      'password': credentials.password,
    }));
  }

  Future<String?> _readRaw() async {
    if (Platform.isMacOS) {
      final preferences = await SharedPreferences.getInstance();
      return preferences.getString(_storageKey);
    }

    return _storage.read(key: _storageKey);
  }

  Future<void> _writeRaw(String value) async {
    if (Platform.isMacOS) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_storageKey, value);
      return;
    }

    await _storage.write(key: _storageKey, value: value);
  }
}
