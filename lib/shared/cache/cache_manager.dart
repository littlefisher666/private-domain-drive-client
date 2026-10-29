import '../../features/file_share/infrastructure/share_cache_store.dart';
import 'disk_document_cache.dart';
import 'disk_image_cache.dart';
import 'local_cache_store.dart';

/// 汇总图片、文档、分享临时文件与相册原图四类本地缓存，
/// 为设置页提供统一的占用统计与清理入口。
///
/// 清理只删除缓存文件，不触碰系统下载目录、会话、传输历史与相册索引。
class CacheManager {
  CacheManager({
    LocalCacheStore? imageCache,
    LocalCacheStore? documentCache,
    LocalCacheStore? shareCacheStore,
    LocalCacheStore? Function()? originalCacheStore,
    Future<void> Function()? onCleared,
  })  : _imageCache = imageCache ?? DiskImageCache.instance,
        _documentCache = documentCache ?? DiskDocumentCache.instance,
        _shareCacheStore = shareCacheStore ?? ShareCacheStore(),
        _originalCacheStore = originalCacheStore,
        _onCleared = onCleared;

  final LocalCacheStore _imageCache;
  final LocalCacheStore _documentCache;
  final LocalCacheStore _shareCacheStore;

  /// 相册原图缓存由相册控制器持有，这里延迟读取以避免初始化顺序耦合。
  final LocalCacheStore? Function()? _originalCacheStore;
  final Future<void> Function()? _onCleared;

  /// 四类缓存占用之和（字节）。
  Future<int> sizeBytes() async {
    var total = 0;
    total += await _imageCache.sizeBytes();
    total += await _documentCache.sizeBytes();
    total += await _shareCacheStore.sizeBytes();
    final original = _originalCacheStore?.call();
    if (original != null) {
      total += await original.sizeBytes();
    }
    return total;
  }

  /// 清理四类缓存，返回实际释放的字节数。
  Future<int> clear() async {
    final before = await sizeBytes();
    await _imageCache.clear();
    await _documentCache.clear();
    await _shareCacheStore.clear();
    final original = _originalCacheStore?.call();
    if (original != null) {
      await original.clear();
    }
    await _onCleared?.call();
    final after = await sizeBytes();
    final freed = before - after;
    return freed > 0 ? freed : 0;
  }
}

/// 以 1024 进制展示缓存大小，保留一位小数。
String formatCacheSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '$bytes B';
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}
