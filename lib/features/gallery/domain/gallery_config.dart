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

  /// 超过该大小的图片不走 OSS 图片处理（服务端限制 ImageTooLarge），
  /// 改为客户端本地生成缩略图上传到缩略图前缀。
  static const int oversizedImageLimit = 20 * 1024 * 1024;

  /// OSS 索引清单对象（相对会话根前缀）。相册内部对象统一收敛在
  /// 点前缀目录下，避免与用户自建目录撞名。
  static const String manifestRelativeKey = '.gallery/index/photos.json';

  /// OSS 视频缩略图对象前缀（相对会话根前缀）。
  static const String thumbRelativePrefix = '.gallery/thumbs/';

  /// 清单写入冲突重试上限。
  static const int manifestWriteMaxAttempts = 3;

  /// 清单对象读取上限（数万条目时可超 1MB，不适用文本预览的 512KB 上限）。
  static const int manifestMaxBytes = 8 * 1024 * 1024;

  /// 全量扫描时并发解析 EXIF 的请求数（工作池常驻 worker 数）。
  /// 受原生 OSS SDK 并发稳定性约束，过高会在原生 HTTP 客户端
  /// 会话释放时触发段错误（实测 96 必崩，32 稳定）。
  static const int scanExifConcurrency = 32;
}
