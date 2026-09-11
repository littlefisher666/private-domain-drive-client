import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/features/settings/application/update_service.dart';
import 'package:private_domain_drive_client/features/settings/infrastructure/github_release_client.dart';

void main() {
  test('解析静态更新清单', () {
    final release = GithubRelease.fromJson({
      'version': '1.0.4',
      'notes': '',
      'assets': {
        'android': {
          'name': 'private-domain-drive-android-v1.0.4.apk',
          'url': 'https://example.com/android.apk',
          'digest': 'sha256:abc',
        },
        'macos': {
          'name': 'private-domain-drive-macos-v1.0.4.dmg',
          'url': 'https://example.com/macos.dmg',
          'digest': 'sha256:def',
        },
      },
    });

    expect(release.version, '1.0.4');
    expect(release.assets, hasLength(2));
    expect(release.assets.first.digest, 'sha256:abc');
  });

  test('比较语义化版本', () {
    expect(UpdateService.compareVersions('1.0.4', '1.0.3'), greaterThan(0));
    expect(UpdateService.compareVersions('v1.0.3', '1.0.3'), 0);
    expect(UpdateService.compareVersions('1.0.2', '1.0.3'), lessThan(0));
  });
}
