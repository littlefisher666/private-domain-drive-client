import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/user_session.dart';

class SecureSessionStore {
  SecureSessionStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  static const _sessionKey = 'pdd.user_session.v1';

  final FlutterSecureStorage _storage;

  Future<UserSession?> read() async {
    final raw = await _readRaw();
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      return UserSession.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(UserSession session) async {
    await _writeRaw(jsonEncode(session.toJson()));
  }

  Future<void> clear() async {
    if (Platform.isMacOS) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(_sessionKey);
      return;
    }

    await _storage.delete(key: _sessionKey);
  }

  Future<String?> _readRaw() async {
    if (Platform.isMacOS) {
      final preferences = await SharedPreferences.getInstance();
      return preferences.getString(_sessionKey);
    }

    return _storage.read(key: _sessionKey);
  }

  Future<void> _writeRaw(String value) async {
    if (Platform.isMacOS) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_sessionKey, value);
      return;
    }

    await _storage.write(key: _sessionKey, value: value);
  }
}
