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
