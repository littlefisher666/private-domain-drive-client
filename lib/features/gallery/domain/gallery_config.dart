/// 相册功能集中配置常量。
class GalleryConfig {
  const GalleryConfig._();

  /// 时间线列表缩略图档位（OSS 图片处理宽度）。
  static const int listThumbnailSize = 400;

  /// 大图查看器未缓存原图时的降级展示档位。
  static const int degradedPreviewSize = 1200;

  /// 原图缓存条目超过该天数未访问即被清理。
  static const int cacheExpireDays = 30;

  /// 原图缓存总容量上限（5 GB）。
  static const int cacheCapacityLimit = 5 * 1024 * 1024 * 1024;

  /// 容量清理的目标阈值（清理至该值以下，约 4.5 GB）。
  static const int cacheCapacityTarget = cacheCapacityLimit - 512 * 1024 * 1024;

  /// OSS 索引清单对象（相对会话根前缀）。
  static const String manifestRelativeKey = 'index/photos.json';

  /// OSS 视频缩略图对象前缀（相对会话根前缀）。
  static const String thumbRelativePrefix = 'thumbs/';

  /// 清单写入冲突重试上限。
  static const int manifestWriteMaxAttempts = 3;

  /// 全量扫描时并发解析 EXIF 的请求数。
  static const int scanExifConcurrency = 4;
}
