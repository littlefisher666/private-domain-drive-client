import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

const _downloadDirectoryPicker =
    MethodChannel('private_domain_drive/download_directory_picker');

/// 打开下载目录选择器；macOS 默认定位到系统“下载”目录。
Future<String?> selectDownloadDirectory() async {
  if (Platform.isAndroid) {
    return _downloadDirectoryPicker.invokeMethod<String>('select');
  }
  if (!Platform.isMacOS) return FilePicker.getDirectoryPath();
  try {
    return await _downloadDirectoryPicker.invokeMethod<String>('select');
  } on MissingPluginException {
    // 原生通道未注册时保留系统选择器作为兼容兜底。
    return FilePicker.getDirectoryPath();
  }
}
