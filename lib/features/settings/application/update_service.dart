import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/version/app_version.dart';
import '../infrastructure/github_release_client.dart';
import '../infrastructure/android_update_installer.dart';
import '../infrastructure/apk_downloader.dart';

class AvailableUpdate {
  const AvailableUpdate({required this.release, required this.asset});
  final GithubRelease release;
  final ReleaseAsset asset;
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    this.availableUpdate,
  });

  final String currentVersion;
  final String latestVersion;
  final AvailableUpdate? availableUpdate;

  bool get hasUpdate =>
      UpdateService.compareVersions(latestVersion, currentVersion) > 0;
}

class UpdateService {
  UpdateService(
      {required AppVersionReader versionReader,
      required GithubReleaseClient releaseClient})
      : _versionReader = versionReader,
        _releaseClient = releaseClient;
  final AppVersionReader _versionReader;
  final GithubReleaseClient _releaseClient;

  Future<AvailableUpdate?> check() async {
    final result = await checkLatest();
    return result.availableUpdate;
  }

  Future<UpdateCheckResult> checkLatest() async {
    final current = await _versionReader.read();
    debugPrint('[更新检查] 当前版本：${current.name}');
    final release = await _releaseClient.latest();
    final comparison = compareVersions(release.version, current.name);
    debugPrint('[更新检查] 远端版本：${release.version}，比较结果：$comparison');
    if (comparison <= 0) {
      return UpdateCheckResult(
        currentVersion: current.name,
        latestVersion: release.version,
      );
    }
    final prefix = defaultTargetPlatform == TargetPlatform.android
        ? 'private-domain-drive-android-v'
        : 'private-domain-drive-macos-v';
    final suffix =
        defaultTargetPlatform == TargetPlatform.android ? '.apk' : '.dmg';
    debugPrint('[更新检查] 查找资产：$prefix*$suffix');
    final asset = release.assets
        .where((item) =>
            item.name.startsWith(prefix) && item.name.endsWith(suffix))
        .firstOrNull;
    if (asset == null) {
      debugPrint('[更新检查] 未找到当前平台的发布资产');
      return UpdateCheckResult(
        currentVersion: current.name,
        latestVersion: release.version,
      );
    }
    debugPrint('[更新检查] 找到发布资产：${asset.name}');
    return UpdateCheckResult(
      currentVersion: current.name,
      latestVersion: release.version,
      availableUpdate: AvailableUpdate(release: release, asset: asset),
    );
  }

  Future<void> openDownload(AvailableUpdate update) =>
      launchUrl(Uri.parse(update.asset.url),
          mode: LaunchMode.externalApplication);

  Stream<ApkDownloadProgress> downloadAndroid(AvailableUpdate update) async* {
    if (defaultTargetPlatform != TargetPlatform.android ||
        update.asset.digest == null) {
      throw StateError('当前更新包不支持应用内安装');
    }
    final downloader = ApkDownloader();
    if (await downloader.hasValidDownload(
      sha256Digest: update.asset.digest!,
      fileName: update.asset.name,
    )) {
      final size = await downloader.downloadedFileSize(update.asset.name);
      if (size != null) {
        debugPrint('[更新检查] 使用已缓存的更新包：${update.asset.name}');
        yield ApkDownloadProgress(received: size, total: size);
      }
    } else {
      debugPrint('[更新检查] 未找到有效缓存，开始下载：${update.asset.name}');
      await for (final progress in downloader.download(
        url: Uri.parse(update.asset.url),
        sha256Digest: update.asset.digest!,
        fileName: update.asset.name,
      )) {
        yield progress;
      }
    }
    final apk = await downloader.downloadedFile(update.asset.name);
    final started = await AndroidUpdateInstaller.install(apk);
    if (!started) throw StateError('请先在系统设置中允许此应用安装未知来源应用');
  }

  static int compareVersions(String left, String right) {
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
}
