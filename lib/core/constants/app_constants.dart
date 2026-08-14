class AppConstants {
  AppConstants._();

  static const appName = 'Private Domain Drive';
  static const appVersion = '0.1.0';

  /// FC base URL. Override at build time:
  /// flutter run --dart-define=FC_BASE_URL=https://xxx
  static const fcBaseUrl = String.fromEnvironment(
    'FC_BASE_URL',
    defaultValue: 'https://privatein-drive-zklxbsdytm.cn-hangzhou.fcapp.run',
  );

  static const fcAccessKeyId = String.fromEnvironment('FC_ACCESS_KEY_ID');
  static const fcAccessKeySecret = String.fromEnvironment('FC_ACCESS_KEY_SECRET');
  static const fcRegion = String.fromEnvironment('FC_REGION', defaultValue: 'cn-hangzhou');
  static const fcService = String.fromEnvironment('FC_SERVICE', defaultValue: 'fc');
  static const fcSignRequests = bool.fromEnvironment('FC_SIGN_REQUESTS', defaultValue: true);

  /// Refresh STS this many minutes before expiration.
  static const stsRefreshSkew = Duration(minutes: 8);

  /// When true, login falls back to local demo session if FC is unavailable.
  static const allowLocalMockFallback = bool.fromEnvironment(
    'ALLOW_LOCAL_MOCK_FALLBACK',
    defaultValue: false,
  );
}
