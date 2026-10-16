part of 'workspace_page.dart';

// _WorkspacePageState 的操作处理器：新建/重命名/删除/别名/下载/移动/
// 上传弹窗等，私有成员经 part 与主文件共享。

extension _WorkspacePageActions on _WorkspacePageState {
  Future<void> _setSortOption(FileSortOption option) async {
    final controller = AppScope.of(context);
    await controller.workspaceController.setFileSortOption(option);
    if (mounted) await _reload();
  }

  void _showSortSheet() {
    showFileSortSheet(
      context,
      current: AppScope.read(context).workspaceController.fileSortOption,
      onSelected: _setSortOption,
    );
  }

  Future<void> _createFolder() async {
    final controller = AppScope.of(context);
    if (!controller.sessionController.capabilities.upload) {
      AppFeedback.showSnack(context, '当前身份没有新建权限');
      return;
    }
    final name = await AppFeedback.promptText(
      context,
      title: '新建文件夹',
      hintText: '请输入文件夹名称',
      confirmLabel: '创建',
    );
    if (name == null) {
      return;
    }
    try {
      await controller.workspaceController.createFolder(name);
      await _reload();
      if (mounted) {
        AppFeedback.showSnack(context, '已创建 $name');
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  void _rename(FileItem item) {
    final controller = AppScope.of(context);
    final allowed = item.isAlias
        ? controller.sessionController.capabilities.upload
        : controller.sessionController.capabilities.upload || controller.sessionController.capabilities.delete;
    if (!allowed) {
      AppFeedback.showSnack(context, '当前身份没有重命名权限');
      return;
    }
    _setState(() =>
        _renamingTarget = (path: item.path, isAlias: item.isAlias));
  }

  void _cancelRename() {
    if (_renamingTarget != null) {
      _setState(() => _renamingTarget = null);
    }
  }

  Future<bool> _commitRename(FileItem item, String name) async {
    final trimmedName = name.trim();
    if (trimmedName == item.name) {
      _cancelRename();
      return true;
    }
    if (trimmedName.isEmpty) {
      AppFeedback.showSnack(context, '名称不能为空');
      return false;
    }
    final controller = AppScope.of(context);
    try {
      if (item.isAlias) {
        await controller.aliasController.renameAlias(item, trimmedName);
      } else {
        await controller.workspaceController.renameItem(item, trimmedName);
      }
      _cancelRename();
      await _reload();
      if (mounted) {
        AppFeedback.showSnack(context, '已重命名为 $trimmedName');
      }
      return true;
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
      return false;
    }
  }

  Future<void> _delete(FileItem item) async {
    if (item.isAlias) {
      await _deleteLink(item);
      return;
    }
    if (_deleteBusy) {
      AppFeedback.showSnack(context, '正在删除中，请稍候…');
      return;
    }
    final controller = AppScope.of(context);
    if (!controller.sessionController.capabilities.delete) {
      AppFeedback.showSnack(context, '当前身份没有删除权限');
      return;
    }
    final confirmed = await AppFeedback.confirm(
      context,
      title: '确认删除？',
      message: '将“${item.name}”移入回收站，30 天内可恢复。',
      confirmLabel: '移入回收站',
      destructive: true,
    );
    if (!confirmed) {
      return;
    }
    _deleteBusy = true;
    try {
      await controller.recycleBinController.deleteItem(item);
      await _reload();
      if (mounted) {
        AppFeedback.showSnack(context, '已移入回收站：${item.name}');
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      _deleteBusy = false;
    }
  }

  /// 为真实文件夹条目创建链接；名称与挂载层级在同一个对话框内完成。
  Future<void> _createLink(FileItem folder) async {
    final controller = AppScope.of(context);
    if (!controller.sessionController.capabilities.upload) {
      AppFeedback.showSnack(context, '当前身份没有创建链接权限');
      return;
    }
    // 默认挂载在当前所在目录，可在弹窗内导航到任意层级；
    // 名称冲突等校验失败时就地提示，弹窗保持打开。
    final created = await showCreateAliasDialog(
      context,
      controller: controller,
      folder: folder,
    );
    if (!created || !mounted) {
      return;
    }
    await _reload();
  }

  /// 删除链接：仅移除别名条目，目标目录内容不受影响。
  Future<void> _deleteLink(FileItem item) async {
    final controller = AppScope.of(context);
    if (!controller.sessionController.capabilities.delete) {
      AppFeedback.showSnack(context, '当前身份没有删除权限');
      return;
    }
    final confirmed = await AppFeedback.confirm(
      context,
      title: '确认删除链接？',
      message: '将仅移除链接“${item.name}”，目标目录及其内容不受影响。',
      confirmLabel: '删除链接',
      destructive: true,
    );
    if (!confirmed) {
      return;
    }
    try {
      await controller.aliasController.deleteAlias(item);
      await _reload();
      if (mounted) {
        AppFeedback.showSnack(context, '已删除链接：${item.name}');
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _download(FileItem item) async {
    if (item.isDirectory) {
      await _downloadSelected(<FileItem>[item]);
      return;
    }
    final controller = AppScope.of(context);
    try {
      final mediaFile = _isAndroidMediaFile(item.name);
      final directory = mediaFile ? '系统相册' : await selectDownloadDirectory();
      if (directory == null) {
        return;
      }
      controller.transferController.enqueueDownload(item, targetDirectory: directory);
      if (mounted) {
        AppFeedback.showSnack(
          context,
          mediaFile ? '已加入相册下载队列：${item.name}' : '已加入下载队列：${item.name}',
        );
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  bool _isAndroidMediaFile(String name) {
    if (!Platform.isAndroid) return false;
    final extension = name.split('.').last.toLowerCase();
    return const <String>{
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'heic',
      'mp4',
      'mov',
      'mkv',
      'avi',
      'webm',
      '3gp',
    }.contains(extension);
  }

  Future<void> _downloadSelected(List<FileItem> items) async {
    final controller = AppScope.of(context);
    final directory = await selectDownloadDirectory();
    if (directory == null) return;
    if (!mounted) return;
    try {
      final directoryCount = items.where((item) => item.isDirectory).length;
      if (directoryCount > 0) {
        AppFeedback.showSnack(context, '正在展开 $directoryCount 个文件夹…');
      }
      final result = await controller.transferController.enqueueDownloadsRecursively(
        items,
        targetDirectory: directory,
      );
      controller.workspaceController.clearMultiSelection();
      if (!mounted) return;
      AppFeedback.showSnack(
        context,
        result.fileCount == 0
            ? '所选文件夹为空，没有可下载文件'
            : '已加入 ${result.fileCount} 个下载任务${result.directoryCount == 0 ? '' : '，已保留文件夹结构'}',
      );
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _deleteSelected(List<FileItem> items) async {
    if (_deleteBusy) {
      AppFeedback.showSnack(context, '正在删除中，请稍候…');
      return;
    }
    final controller = AppScope.of(context);
    // 链接条目删除走单独的「删除链接」流程，批量删除只作用于真实条目，
    // 避免把别名当成真实目录展开删除。
    final realItems =
        items.where((item) => !item.isAlias).toList(growable: false);
    if (realItems.isEmpty) {
      AppFeedback.showSnack(context, '链接条目请使用「删除链接」操作');
      return;
    }
    AppFeedback.showSnack(context, '正在统计待删除对象…');
    _deleteBusy = true;
    try {
      final preview = await controller.recycleBinController.prepareBatchDelete(realItems);
      if (!mounted) return;
      final confirmed = await AppFeedback.confirm(
        context,
        title: '确认删除 ${preview.selectedCount} 项？',
        message:
            '其中包含 ${preview.directoryCount} 个文件夹，共影响 ${preview.objectCount} 个对象。'
            '将移入回收站，30 天内可恢复。',
        confirmLabel: '移入回收站',
        destructive: true,
      );
      if (!confirmed) return;
      // 立即清空多选，避免删除进行中同一批条目被再次提交。
      controller.workspaceController.clearMultiSelection();
      var result = await controller.recycleBinController.deleteBatch(preview);
      if (result.failedPaths.isNotEmpty && mounted) {
        final retry = await AppFeedback.confirm(
          context,
          title: '部分删除失败',
          message:
              '已删除 ${result.deletedPaths.length} 项，${result.failedPaths.length} 项失败。是否重试失败项？',
          confirmLabel: '重试失败项',
        );
        if (retry) {
          final retried = await controller.recycleBinController.retryBatchDelete(result.failedPaths);
          result = BatchDeleteSummary(
            deletedPaths: <String>[
              ...result.deletedPaths,
              ...retried.deletedPaths
            ],
            failedPaths: retried.failedPaths,
          );
        }
      }
      await _reload();
      if (mounted) {
        AppFeedback.showSnack(
          context,
          result.failedPaths.isEmpty
              ? '已移入回收站 ${result.deletedPaths.length} 项'
              : '已移入回收站 ${result.deletedPaths.length} 项，${result.failedPaths.length} 项失败',
        );
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
            context, error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      _deleteBusy = false;
    }
  }

  Future<void> _pickUpload({required bool fromAlbum}) async {
    await pickAndUploadFile(context, fromAlbum: fromAlbum);
    if (mounted) await _reload();
  }

  /// 单条目与批量移动共用入口：能力检查 → 目录选择 → 执行与反馈。
  Future<void> _moveItems(List<FileItem> items) async {
    final controller = AppScope.of(context);
    if (!controller.sessionController.capabilities.upload || !controller.sessionController.capabilities.delete) {
      AppFeedback.showSnack(context, '当前身份没有移动权限');
      return;
    }
    if (controller.moveController.isMoving) {
      AppFeedback.showSnack(context, '已有移动任务进行中，请等待完成');
      return;
    }
    // 链接条目不可移动；移动目标选择器中选中链接等价于其真实目标前缀。
    final realItems =
        items.where((item) => !item.isAlias).toList(growable: false);
    if (realItems.isEmpty) {
      AppFeedback.showSnack(context, '链接条目不支持移动');
      return;
    }
    // 非法目标：任何源目录自身/子树（含后代全部禁用），以及源所在目录（仅禁其自身）。
    final invalidPrefixes = <String>{
      for (final item in realItems.where((item) => item.isDirectory))
        item.path,
    };
    final invalidPaths = <String>{
      if (realItems.isNotEmpty) path_utils.parentPathOf(realItems.first.path),
    };
    final target = await showDirectoryPickerDialog(
      context,
      controller: controller,
      invalidPrefixes: invalidPrefixes,
      invalidPaths: invalidPaths,
    );
    if (target == null || !mounted) {
      return;
    }
    try {
      final summary = await controller.moveController.moveItems(realItems, target);
      if (!mounted) {
        return;
      }
      await _reload();
      if (summary == null || !mounted) {
        return;
      }
      AppFeedback.showSnack(
        context,
        summary.hasFailures
            ? '已移动 ${summary.movedCount} 个对象，${summary.failedKeys.length} 个失败，'
                '重新启动后可继续或撤销'
            : '已移动 ${realItems.length} 项到「${controller.workspaceController.displayPath(target)}」',
      );
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  /// 冷启动（或重新登录）后检测残留移动任务，逐个提示继续或撤销。
  Future<void> _checkPendingMoves() async {
    final controller = AppScope.read(context);
    if (!controller.sessionController.isLoggedIn) {
      return;
    }
    try {
      final pending = await controller.moveController.listPendingMoves();
      for (final entry in pending) {
        if (!mounted) {
          return;
        }
        final resume = await _showPendingMoveDialog(entry);
        if (resume == null) {
          continue;
        }
        try {
          final summary = resume
              ? await controller.moveController.resumePendingMove(entry)
              : await controller.moveController.undoPendingMove(entry);
          if (!mounted) {
            return;
          }
          await _reload();
          if (!mounted) {
            return;
          }
          AppFeedback.showSnack(
            context,
            summary.hasFailures
                ? '有 ${summary.failedKeys.length} 个对象处理失败，'
                    '重新启动后可继续或撤销'
                : resume
                    ? '已继续完成移动'
                    : '已撤销移动并恢复原位置',
          );
        } catch (error) {
          if (mounted) {
            AppFeedback.showSnack(
              context,
              error.toString().replaceFirst('Bad state: ', ''),
            );
          }
        }
      }
    } catch (_) {
      // 未登录或会话未就绪时不做恢复提示。
    }
  }

  Future<bool?> _showPendingMoveDialog(MoveTaskEntry entry) {
    final controller = AppScope.read(context);
    final createdAt = entry.createdAt;
    final mm = createdAt.month.toString().padLeft(2, '0');
    final dd = createdAt.day.toString().padLeft(2, '0');
    final hh = createdAt.hour.toString().padLeft(2, '0');
    final mi = createdAt.minute.toString().padLeft(2, '0');
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final sources = entry.sourcePrefixes
            .map((prefix) => '「${controller.workspaceController.displayPath(prefix)}」')
            .toList();
        final sourceText = sources.length == 1
            ? sources.first
            : '${sources.first} 等 ${sources.length} 项';
        return AlertDialog(
          title: const Text('存在未完成的移动任务'),
          content: Text(
            '一次移动在 $mm-$dd $hh:$mi 中断：原计划把 $sourceText '
            '移动到「${controller.workspaceController.displayPath(entry.targetPrefix)}」。\n\n'
            '「继续移动」会接着完成这次搬运；「撤销移动」会把已经搬到'
            '「${controller.workspaceController.displayPath(entry.targetPrefix)}」的内容搬回原位置。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('暂不处理'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('撤销移动'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('继续移动'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickUploadDirectory() async {
    await pickAndUploadDirectory(context);
    if (mounted) await _reload();
  }

  Future<void> _showUploadSheet() async {
    final controller = AppScope.of(context);
    if (!controller.sessionController.capabilities.upload) {
      AppFeedback.showSnack(context, '当前身份没有上传权限');
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                dense: true,
                leading: const Icon(Icons.upload_file_outlined, size: 22),
                title: const Text('上传文件'),
                onTap: () {
                  Navigator.pop(context);
                  _pickUpload(fromAlbum: false);
                },
              ),
              ListTile(
                dense: true,
                leading:
                    const Icon(Icons.drive_folder_upload_outlined, size: 22),
                title: const Text('上传文件夹'),
                onTap: () {
                  Navigator.pop(context);
                  _pickUploadDirectory();
                },
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.photo_outlined, size: 22),
                title: const Text('从相册上传'),
                onTap: () {
                  Navigator.pop(context);
                  _pickUpload(fromAlbum: true);
                },
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.create_new_folder_outlined, size: 22),
                title: const Text('新建文件夹'),
                onTap: () {
                  Navigator.pop(context);
                  _createFolder();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showItemActions(FileItem item) async {
    final controller = AppScope.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.82,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ListTile(
                    dense: true,
                    title: Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    subtitle: Text(
                      controller.workspaceController.displayPath(item.path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ListTile(
                    dense: true,
                    leading: Icon(
                        item.isDirectory
                            ? Icons.open_in_new
                            : Icons.visibility_outlined,
                        size: 22),
                    title: Text(item.isDirectory ? '打开' : '预览'),
                    onTap: () {
                      Navigator.pop(context);
                      _handleOpen(item);
                    },
                  ),
                  if (!item.isAlias && controller.sessionController.capabilities.download)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.download_outlined, size: 22),
                      title: const Text('下载'),
                      onTap: () {
                        Navigator.pop(context);
                        _download(item);
                      },
                    ),
                  if (!item.isAlias &&
                      controller.sessionController.capabilities.upload &&
                      controller.sessionController.capabilities.delete)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.drive_file_move_outlined,
                          size: 22),
                      title: const Text('移动到…'),
                      onTap: () {
                        Navigator.pop(context);
                        _moveItems(<FileItem>[item]);
                      },
                    ),
                  if (!item.isAlias &&
                      item.isDirectory &&
                      controller.sessionController.capabilities.upload)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.add_link, size: 22),
                      title: const Text('创建链接'),
                      onTap: () {
                        Navigator.pop(context);
                        _createLink(item);
                      },
                    ),
                  if (item.isAlias
                      ? controller.sessionController.capabilities.upload
                      : controller.sessionController.capabilities.upload ||
                          controller.sessionController.capabilities.delete)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.edit_outlined, size: 22),
                      title: const Text('重命名'),
                      onTap: () {
                        Navigator.pop(context);
                        _rename(item);
                      },
                    ),
                  if (item.isAlias && controller.sessionController.capabilities.delete)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.link_off,
                        size: 22,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      title: Text(
                        '删除链接',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        _deleteLink(item);
                      },
                    ),
                  if (!item.isAlias && controller.sessionController.capabilities.delete)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.delete_outline,
                        size: 22,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      title: Text(
                        '删除',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        _delete(item);
                      },
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
