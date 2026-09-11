import 'dart:io';

import 'package:flutter/services.dart';

class AndroidUpdateInstaller {
  AndroidUpdateInstaller._();

  static const _channel = MethodChannel('private_domain_drive/app_update');

  static Future<bool> install(File apk) async =>
      await _channel.invokeMethod<bool>('installApk', {'path': apk.path}) ??
      false;
}
