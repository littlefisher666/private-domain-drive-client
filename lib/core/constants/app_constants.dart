class AppConstants {
  AppConstants._();

  static const appName = 'Private Domain Drive';
  static const appVersion = '0.1.0';

  /// FC base URL. Override at build time:
  /// flutter run --dart-define=FC_BASE_URL=https://xxx
  static const fcBaseUrl = String.fromEnvironment(
    'FC_BASE_URL',
    defaultValue: 'http://127.0.0.1:9000',
  );

  /// Refresh STS this many minutes before expiration.
  static const stsRefreshSkew = Duration(minutes: 8);

  /// When true, login falls back to local demo session if FC is unavailable.
  static const allowLocalMockFallback = bool.fromEnvironment(
    'ALLOW_LOCAL_MOCK_FALLBACK',
    defaultValue: true,
  );
}
