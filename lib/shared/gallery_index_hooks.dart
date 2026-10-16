/// 相册功能在传输与删除生命周期中的挂钩点。
/// 由 gallery 模块实现并在启动时注入；未注入时全部为空操作。
abstract interface class GalleryIndexHooks {
  /// 视频上传前启动本地截帧（与上传并行）；返回截帧 JPEG 的本地路径，
  /// 截帧失败返回 null，不阻塞上传。
  Future<String?> prepareVideoThumbnail(String objectPath, String localPath);

  /// 超大图片上传前本地生成缩略图（与上传并行）；非超大图或生成失败
  /// 返回 null，不阻塞上传。
  Future<String?> prepareImageThumbnail(String objectPath, String localPath);

  /// 媒体上传成功后触发索引增量更新（非媒体文件由实现方过滤）。
  Future<void> onMediaUploaded({
    required String objectPath,
    required String localPath,
    String? thumbLocalPath,
  });

  /// 对象删除成功后触发索引增量清理（对象 key，含目录展开结果）。
  Future<void> onObjectsDeleted(Set<String> objectKeys);

  /// 对象从回收站还原后重新纳入索引。
  Future<void> onObjectsRestored(Set<String> objectKeys);
}
