import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _downloadDirectoryPicker =
    MethodChannel('private_domain_drive/download_directory_picker');

/// 记住用户最后一次确认的下载目录；Android 存 content URI，桌面存路径。
class DownloadDirectoryStore {
  DownloadDirectoryStore({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  static const _key = 'download_directory:v1';

  final Future<SharedPreferences> Function() _preferences;

  Future<String?> read() async {
    final preferences = await _preferences();
    final value = preferences.getString(_key);
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> save(String directory) async {
    if (directory.isEmpty) return;
    final preferences = await _preferences();
    await preferences.setString(_key, directory);
  }
}

/// 打开下载目录选择器，并默认定位到上次确认的目录。
///
/// 取消选择时不写入记忆；记忆中目录失效时由原生侧回退到系统下载目录。
Future<String?> selectDownloadDirectory({
  DownloadDirectoryStore? store,
}) async {
  final directoryStore = store ?? DownloadDirectoryStore();
  final initialDirectory = await directoryStore.read();

  String? selected;
  if (defaultTargetPlatform == TargetPlatform.android) {
    selected = await _invokeSelect(initialDirectory);
  } else if (defaultTargetPlatform == TargetPlatform.macOS) {
    try {
      selected = await _invokeSelect(initialDirectory);
    } on MissingPluginException {
      // 原生通道未注册时保留系统选择器作为兼容兜底。
      selected = await FilePicker.getDirectoryPath(
        initialDirectory: initialDirectory,
      );
    }
  } else {
    selected = await FilePicker.getDirectoryPath(
      initialDirectory: initialDirectory,
    );
  }

  if (selected == null || selected.isEmpty) return null;
  await directoryStore.save(selected);
  return selected;
}

Future<String?> _invokeSelect(String? initialDirectory) {
  return _downloadDirectoryPicker.invokeMethod<String>('select', <String, Object?>{
    'initialDirectory': initialDirectory,
  });
}
