part of 'workspace_controller.dart';

/// WorkspaceController 的目录列举与统计摘要实现：目录浏览、别名
/// 条目合并、目录选择器列举、目录统计缓存转发与按拍摄时间排序。
mixin _WorkspaceControllerListing on _WorkspaceControllerCore {
  // ---------- 浏览 / 列表 ----------

  Future<List<FileItem>> listDirectory([String? path]) async {
    final session = _sessionController.session;
    if (session == null || !session.isRemote || session.credentials == null) {
      throw AppError('请先登录', code: 'REMOTE_SESSION_REQUIRED');
    }
    await _sessionController.ensureSessionReady();
    final target = path ?? _currentPath;
    final results = await Future.wait<dynamic>([
      _ossClient.list(target, session),
      _loadAliasTable(session),
    ]);
    final items = results[0] as List<FileItem>;
    final merged = await _mergeAliasItems(items, session, target);
    if (target == _currentPath) {
      final beforeCount = _remoteDirectories.length;
      _remoteDirectories
        ..add(_currentPath)
        ..addAll(
            merged.where((item) => item.isDirectory).map((item) => item.path));
      if (_remoteDirectories.length != beforeCount) {
        notifyListeners();
      }
    }
    return _sortDirectoryItems(
      merged,
      session,
      _fileSortOptionForPath(target),
    );
  }

  /// 刷新别名表；读取失败保留旧表，不阻塞目录浏览。
  Future<void> _loadAliasTable(UserSession session) async {
    try {
      _aliasTable = await _aliasRepository.load(session);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[alias] 别名表加载失败，沿用旧表: $error');
      }
    }
  }

  /// 将挂载于 [path] 层级的别名条目合并进目录列表：渲染为带链接标识的
  /// 文件夹，统计信息取目标前缀的直属内容，计入所在层级条目统计。
  Future<List<FileItem>> _mergeAliasItems(
    List<FileItem> items,
    UserSession session,
    String path,
  ) async {
    if (_aliasTable.isEmpty) return items;
    final level = normalizeDirPath(path);
    final mounted = _aliasTable.aliases
        .where((alias) => normalizeDirPath(alias.parentPrefix) == level)
        .toList(growable: false);
    if (mounted.isEmpty) return items;
    // 同层级别名允许指向同层真实目录（如目录改名快捷入口），此时真实
    // 条目与别名条目并列展示；批量操作按 isAlias 区分二者。
    final summaries = await Future.wait<DirectorySummary?>(
      mounted.map((alias) async {
        try {
          return await _ossClient.directorySummary(alias.targetPrefix, session);
        } catch (_) {
          return null;
        }
      }),
    );
    return <FileItem>[
      ...items,
      for (var index = 0; index < mounted.length; index++)
        FileItem(
          path: mounted[index].targetPrefix,
          name: mounted[index].name,
          isDirectory: true,
          itemCount: summaries[index]?.itemCount,
          updatedAt: summaries[index]?.updatedAt,
          isAlias: true,
          aliasId: mounted[index].id,
          createdBy: mounted[index].createdBy,
        ),
    ];
  }

  /// 目录选择器专用：仅前缀列举子目录（单次请求），不做子内容统计。
  Future<List<FileItem>> listSubdirectories(String path) async {
    final session = _sessionController.session;
    if (session == null || !session.isRemote || session.credentials == null) {
      throw AppError('请先登录', code: 'REMOTE_SESSION_REQUIRED');
    }
    await _sessionController.ensureSessionReady();
    final prefix = normalizeDirPath(path);
    final prefixes = await _ossClient.listPrefixes(prefix, session);
    return <FileItem>[
      for (final dirPrefix in prefixes)
        if (!dirPrefix.substring(prefix.length).startsWith('.'))
          FileItem(
            path: dirPrefix,
            name: dirPrefix.substring(prefix.length, dirPrefix.length - 1),
            isDirectory: true,
          ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// 目录选择器使用：与 [listSubdirectories] 一致，但按层级合并挂载于
  /// [path] 的别名条目（path 指向目标目录），使别名可作为移动/挂载目标。
  Future<List<FileItem>> listPickerDirectories(String path) async {
    final directories = await listSubdirectories(path);
    if (_aliasTable.aliases.isEmpty) {
      return directories;
    }
    final level = normalizeDirPath(path);
    final realPaths = directories.map((item) => item.path).toSet();
    final aliasItems = <FileItem>[
      for (final alias in _aliasTable.aliases)
        if (normalizeDirPath(alias.parentPrefix) == level &&
            realPaths.add(alias.targetPrefix))
          FileItem(
            path: alias.targetPrefix,
            name: alias.name,
            isDirectory: true,
            isAlias: true,
            createdBy: alias.createdBy,
          ),
    ];
    if (aliasItems.isEmpty) return directories;
    return [...directories, ...aliasItems]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  // ---------- 目录统计摘要 ----------

  /// 读取单个目录统计的缓存命中值；未命中返回 null。
  Future<DirectorySummary?> cachedDirectorySummary(String path) =>
      _directorySummaryService.cached(path);

  /// 批量读取目录统计缓存命中值，key 为目录路径。
  Future<Map<String, DirectorySummary>> cachedDirectorySummaries(
          Iterable<String> paths) =>
      _directorySummaryService.cachedAll(paths);

  /// 后台受限并发统计子文件夹并逐个回调，不阻塞调用方。
  Future<void> refreshDirectorySummaries(
    Iterable<String> paths, {
    required void Function(String path, DirectorySummary summary) onResult,
  }) =>
      _directorySummaryService.refresh(paths, onResult);

  void noteDirectoryFilesAdded(String dir, int count, DateTime at) =>
      _directorySummaryService.noteFilesAdded(dir, count, at);

  void noteDirectoryFilesRemoved(String dir, int count) =>
      _directorySummaryService.noteFilesRemoved(dir, count);

  void invalidateDirectorySummary(String dir) =>
      _directorySummaryService.invalidate(dir);

  /// 回收站清理等不可靠路径调用 invalidate。写修正后同时触发该目录的
  /// 后台校准，让计数最终与 OSS 一致；校准不阻塞操作反馈。
  void calibrateDirectorySummary(String dir) {
    unawaited(_directorySummaryService.refresh(<String>[dir], (_, __) {}));
  }

  /// 对一组成功删除/新增的顶层条目按所属目录修正统计缓存。
  void noteTopLevelChanges(
    Iterable<String> topLevelPaths,
    Set<String> failedPaths, {
    required int delta,
  }) {
    final affected = <String>{};
    final counts = <String, int>{};
    for (final path in topLevelPaths) {
      final parent = normalizeDirPath(parentPathOf(path));
      affected.add(parent);
      if (failedPaths.contains(path)) {
        // 该条目未能删除/搬运，无法可靠增量，直接失效由校准重建。
        _directorySummaryService.invalidate(parent);
        continue;
      }
      counts[parent] = (counts[parent] ?? 0) + delta.abs();
    }
    counts.forEach((dir, count) {
      if (delta >= 0) {
        _directorySummaryService.noteFilesAdded(dir, count, DateTime.now());
      } else {
        _directorySummaryService.noteFilesRemoved(dir, count);
      }
    });
    for (final dir in affected) {
      calibrateDirectorySummary(dir);
    }
  }

  Future<List<FileItem>> _sortDirectoryItems(
    List<FileItem> items,
    UserSession session,
    FileSortOption sortOption,
  ) async {
    if (!sortOption.needsTakenAt) {
      return sortFileItems(items, sortOption);
    }

    SharedPreferences? preferences;
    try {
      preferences = await SharedPreferences.getInstance();
    } catch (_) {
      // 读取 EXIF 仍可用，只是不跨重启缓存。
    }
    // 避免大目录首次按拍摄时间排序时同时发起过多 OSS 请求。
    const concurrency = 6;
    final resolved = <FileItem>[];
    for (var start = 0; start < items.length; start += concurrency) {
      final end = start + concurrency > items.length
          ? items.length
          : start + concurrency;
      resolved.addAll(await Future.wait(items.sublist(start, end).map(
            (item) => _loadItemTakenAt(item, session, preferences),
          )));
    }
    return sortFileItems(resolved, sortOption);
  }
}
