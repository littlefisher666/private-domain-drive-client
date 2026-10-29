/// 可统计占用并清理的本地缓存仓库。
abstract interface class LocalCacheStore {
  Future<int> sizeBytes();

  Future<void> clear();
}
