class AppConstants {
  AppConstants._();

  static const appName = 'Private Domain Drive';

  /// FC base URL. Override at build time:
  /// flutter run --dart-define=FC_BASE_URL=https://xxx
  static const fcBaseUrl = String.fromEnvironment(
    'FC_BASE_URL',
    defaultValue: 'https://privatein-drive-zklxbsdytm.cn-hangzhou.fcapp.run',
  );

  static const fcAccessKeyId = String.fromEnvironment('FC_ACCESS_KEY_ID');
  static const fcAccessKeySecret =
      String.fromEnvironment('FC_ACCESS_KEY_SECRET');
  static const fcRegion =
      String.fromEnvironment('FC_REGION', defaultValue: 'cn-hangzhou');
  static const fcService =
      String.fromEnvironment('FC_SERVICE', defaultValue: 'fc');

  /// FC HTTP 触发器要求签名请求；如本地调试入口明确关闭鉴权，可显式传入 false。
  static const fcSignRequests =
      bool.fromEnvironment('FC_SIGN_REQUESTS', defaultValue: true);

  /// 关闭启动检查：同时跳过更新提示的静默检查与强制升级门禁检查
  /// （本地调试用）；设置页手动检查不受影响。
  static const disableStartupUpdateCheck =
      bool.fromEnvironment('DISABLE_STARTUP_UPDATE_CHECK');

  /// OSS 发布目录公开直链前缀（`releases/` 前缀公开读），与发布流水线
  /// `OSS_MIRROR_BASE_URL` 保持一致。更新发现链路优先读取其固定路径
  /// 清单/appcast，不可用时回退 GitHub 链路。
  static const ossMirrorBaseUrl =
      'https://private-domain-drive.oss-cn-hangzhou.aliyuncs.com';
}
