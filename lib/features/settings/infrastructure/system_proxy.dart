import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _systemProxyChannel =
    MethodChannel('private_domain_drive/system_proxy');

/// 读取平台系统级代理设置，转换为 dart:io HttpClient.findProxy 可用的
/// 配置串。仅用于更新检查这类访问 GitHub 的请求，不影响业务接口的直连行为。
Future<String?> resolveSystemProxy() async {
  if (Platform.isMacOS) return _resolveMacSystemProxy();
  if (Platform.isAndroid) return _resolveAndroidSystemProxy();
  return null;
}

Future<String?> _resolveAndroidSystemProxy() async {
  try {
    final proxy =
        await _systemProxyChannel.invokeMethod<Map<Object?, Object?>>(
      'getDefaultProxy',
    );
    final host = proxy?['host'] as String?;
    final port = proxy?['port'] as int?;
    if (host == null || host.isEmpty || port == null) return null;
    return 'PROXY $host:$port';
  } on PlatformException catch (error) {
    debugPrint('[更新检查] 读取安卓系统代理失败：${error.code} ${error.message}');
    return null;
  } on MissingPluginException {
    return null;
  }
}

Future<String?> _resolveMacSystemProxy() async {
  final ProcessResult result;
  try {
    result = await Process.run('scutil', ['--proxy']);
  } catch (error) {
    return null;
  }
  if (result.exitCode != 0) return null;
  return _parseScutilProxy(result.stdout as String);
}

String? _parseScutilProxy(String output) {
  final settings = <String, String>{};
  for (final line in output.split('\n')) {
    final match = RegExp(r'^\s*(\w+)\s*:\s*(\S+)\s*$').firstMatch(line);
    if (match != null) settings[match.group(1)!] = match.group(2)!;
  }

  String? enabledProxy(String enableKey, String hostKey, String portKey) {
    if (settings[enableKey] != '1') return null;
    final host = settings[hostKey];
    final port = int.tryParse(settings[portKey] ?? '');
    if (host == null || host.isEmpty || port == null) return null;
    return '$host:$port';
  }

  final httpProxy = enabledProxy('HTTPEnable', 'HTTPProxy', 'HTTPPort');
  final httpsProxy = enabledProxy('HTTPSEnable', 'HTTPSProxy', 'HTTPSPort');
  final parts = <String>[
    if (httpsProxy != null) 'PROXY $httpsProxy',
    if (httpProxy != null && httpProxy != httpsProxy) 'PROXY $httpProxy',
  ];
  if (parts.isEmpty) {
    final socksProxy = enabledProxy('SOCKSEnable', 'SOCKSProxy', 'SOCKSPort');
    if (socksProxy != null) parts.add('SOCKS $socksProxy');
  }
  return parts.isEmpty ? null : parts.join('; ');
}
