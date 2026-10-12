import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 上传源文件 staging 管理：把位于应用缓存目录（系统可随时清理）中的
/// 待上传文件迁移到应用持久目录（`upload-staging/`），使任务在应用被杀
/// 后仍可恢复；持久路径（如 macOS 本地磁盘选择的文件）不迁移。
///
/// 迁移使用 move（同一文件系统内为 rename，跨文件系统回退 copy+delete），
/// 不会产生双份占用。清理以「源路径位于 staging 目录内」为判定依据。
class UploadStaging {
  UploadStaging({
    Future<Directory> Function()? temporaryDirectoryProvider,
    Future<Directory> Function()? supportDirectoryProvider,
  })  : _temporaryDirectoryProvider =
            temporaryDirectoryProvider ?? getTemporaryDirectory,
        _supportDirectoryProvider =
            supportDirectoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _temporaryDirectoryProvider;
  final Future<Directory> Function() _supportDirectoryProvider;

  static const _stagingDirName = 'upload-staging';

  Directory? _cachedStaging;
  Directory? _cachedCache;

  /// staging 目录（懒加载并缓存；目录不存在时自动创建）。
  Future<Directory> stagingDirectory() async {
    final cached = _cachedStaging;
    if (cached != null) return cached;
    final support = await _supportDirectoryProvider();
    final staging = Directory('${support.path}${Platform.pathSeparator}$_stagingDirName');
    await staging.create(recursive: true);
    _cachedStaging = staging;
    return staging;
  }

  /// 判断 [path] 是否位于 staging 目录内。
  Future<bool> isInStaging(String path) async {
    final staging = await _stagingPathPrefix();
    return _isUnder(path, staging);
  }

  /// 判断 [path] 是否位于应用缓存目录内（系统可能随时清理的路径）。
  Future<bool> isInCache(String path) async {
    final cache = await _cachePathPrefix();
    return _isUnder(path, cache);
  }

  /// 若 [sourcePath] 位于应用缓存目录，则迁移到
  /// `upload-staging/<taskId>-<fileName>` 并返回新路径；否则原样返回。
  ///
  /// 已在 staging 目录内的路径视为迁移完成，直接返回原路径（幂等）。
  Future<String> migrateIfNeeded(String sourcePath, String taskId) async {
    if (sourcePath.isEmpty) return sourcePath;
    if (await isInStaging(sourcePath)) return sourcePath;
    if (!await isInCache(sourcePath)) return sourcePath;
    final staging = await stagingDirectory();
    final fileName = sourcePath
        .split(Platform.pathSeparator)
        .where((segment) => segment.isNotEmpty)
        .last;
    final targetPath =
        '${staging.path}${Platform.pathSeparator}$taskId-$fileName';
    final source = File(sourcePath);
    final target = File(targetPath);
    try {
      try {
        await source.rename(targetPath);
      } on FileSystemException {
        // 跨文件系统 rename 失败时回退 copy+delete，仍保证原缓存文件被清理。
        await source.copy(targetPath);
        await source.delete();
      }
      return target.path;
    } catch (_) {
      // 迁移失败时清理可能残留的半成品，继续使用原路径上传。
      if (await target.exists()) {
        try {
          await target.delete();
        } catch (_) {}
      }
      return sourcePath;
    }
  }

  /// 清理 [sourcePath] 对应的 staging 文件；路径不在 staging 目录内时
  /// 不做任何操作（不误删缓存外或 OSS 侧路径）。
  Future<void> cleanup(String? sourcePath) async {
    if (sourcePath == null || sourcePath.isEmpty) return;
    if (!await isInStaging(sourcePath)) return;
    try {
      final file = File(sourcePath);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 清理失败不阻塞任务流程；残留文件随应用卸载清理。
    }
  }

  Future<String> _stagingPathPrefix() async {
    final staging = await stagingDirectory();
    return _normalizePrefix(staging.path);
  }

  Future<String> _cachePathPrefix() async {
    final cached = _cachedCache;
    if (cached != null) return _normalizePrefix(cached.path);
    final cache = await _temporaryDirectoryProvider();
    _cachedCache = cache;
    return _normalizePrefix(cache.path);
  }

  static String _normalizePrefix(String path) {
    var normalized = path.endsWith(Platform.pathSeparator)
        ? path
        : '$path${Platform.pathSeparator}';
    return normalized;
  }

  static bool _isUnder(String path, String prefix) {
    return path.startsWith(prefix);
  }
}
