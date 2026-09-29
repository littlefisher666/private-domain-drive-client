import 'package:package_info_plus/package_info_plus.dart';

class AppVersion {
  const AppVersion({required this.name, required this.buildNumber});

  final String name;
  final String buildNumber;

  factory AppVersion.fromPackageInfo(PackageInfo info) => AppVersion(
        name: info.version,
        buildNumber: info.buildNumber,
      );

  String get displayValue => name;
}

abstract class AppVersionReader {
  Future<AppVersion> read();
}

class PackageAppVersionReader implements AppVersionReader {
  @override
  Future<AppVersion> read() async =>
      AppVersion.fromPackageInfo(await PackageInfo.fromPlatform());
}

/// 语义化版本比较：允许 `v` 前缀、忽略 `+build` 元数据，缺失段按 0 处理。
int compareAppVersions(String left, String right) {
  List<int> parse(String value) => value
      .replaceFirst(RegExp(r'^v'), '')
      .split('+')
      .first
      .split('.')
      .map(int.tryParse)
      .map((n) => n ?? 0)
      .toList();
  final a = parse(left), b = parse(right);
  for (var i = 0; i < 3; i++) {
    final result =
        (i < a.length ? a[i] : 0).compareTo(i < b.length ? b[i] : 0);
    if (result != 0) return result;
  }
  return 0;
}
