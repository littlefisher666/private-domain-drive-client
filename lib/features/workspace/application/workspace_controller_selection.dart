part of 'workspace_controller.dart';

/// WorkspaceController 的选择实现：单选与目录大小异步计算、多选/
/// 框选、全选与键盘移动选择。
mixin _WorkspaceControllerSelection on _WorkspaceControllerCore {
  // ---------- 选择 ----------

  void selectItem(FileItem? item) {
    final current = selectedItemListenable.value;
    if (current?.path == item?.path &&
        current?.name == item?.name &&
        current?.isDirectory == item?.isDirectory) {
      // Keep object fresh for rename/metadata without extra noise when identical.
      if (!identical(current, item)) {
        selectedItemListenable.value = item;
      }
      if (item?.isDirectory ?? false) {
        unawaited(_loadDirectorySize(item!));
      }
      return;
    }
    selectedItemListenable.value = item;
    if (item != null && item.kind == FileKind.image && item.takenAt == null) {
      unawaited(_loadSelectedImageTakenAt(item));
    }
    if (item?.isDirectory ?? false) {
      unawaited(_loadDirectorySize(item!));
    }
  }

  void clearSelectedItem() {
    selectedItemListenable.value = null;
  }

  Future<void> _loadDirectorySize(FileItem item) async {
    final path = normalizeDirPath(item.path);
    final cached = _directorySizeCache[path];
    if (cached != null) {
      _setDirectorySizeState(path, DirectorySizeState.ready(cached));
      return;
    }
    if (_directorySizeRequests.containsKey(path)) return;

    final request = Object();
    _directorySizeRequests[path] = request;
    _setDirectorySizeState(path, const DirectorySizeState.loading());
    try {
      await _sessionController.ensureSessionReady();
      final size = await _ossClient.calculateDirectorySize(
        path,
        _sessionController.requireSession(),
      );
      if (_directorySizeRequests[path] == request) {
        _directorySizeCache[path] = size;
        _setDirectorySizeState(path, DirectorySizeState.ready(size));
      }
    } catch (_) {
      if (_directorySizeRequests[path] == request) {
        _setDirectorySizeState(path, const DirectorySizeState.failed());
      }
    } finally {
      if (_directorySizeRequests[path] == request) {
        _directorySizeRequests.remove(path);
      }
    }
  }

  void _setDirectorySizeState(String path, DirectorySizeState state) {
    directorySizeStatesListenable.value = Map<String,
        DirectorySizeState>.unmodifiable(<String, DirectorySizeState>{
      ...directorySizeStatesListenable.value,
      path: state,
    });
  }

  void clearDirectorySizeCache() {
    _directorySizeCache.clear();
    _directorySizeRequests.clear();
    directorySizeStatesListenable.value = const <String, DirectorySizeState>{};
  }

  Future<void> _loadSelectedImageTakenAt(FileItem item) async {
    final session = _sessionController.session;
    if (session == null || !session.isRemote || session.credentials == null) {
      return;
    }
    final resolved = await _loadItemTakenAt(item, session);
    final selected = selectedItemListenable.value;
    if (selected?.path == item.path &&
        selected?.objectVersionToken == item.objectVersionToken) {
      selectedItemListenable.value = resolved;
    }
  }

  void enterMultiSelection([FileItem? initial]) {
    _isMultiSelectionMode = true;
    if (initial != null) {
      _selectionAnchorPath = initial.path;
      multiSelectedPathsListenable.value = <String>{initial.path};
    }
    notifyListeners();
  }

  void toggleMultiSelection(FileItem item,
      {List<FileItem>? visibleItems, bool range = false}) {
    // 链接条目与真实条目可能共用同一路径（同层指向），批量操作按 isAlias
    // 区分二者；多选基于路径无法区分，故链接条目不参与多选。
    if (item.isAlias) {
      return;
    }
    if (!_isMultiSelectionMode) {
      enterMultiSelection(item);
      return;
    }
    final next = <String>{...multiSelectedPathsListenable.value};
    if (range && visibleItems != null && _selectionAnchorPath != null) {
      final anchor = visibleItems
          .indexWhere((value) => value.path == _selectionAnchorPath);
      final target =
          visibleItems.indexWhere((value) => value.path == item.path);
      if (anchor >= 0 && target >= 0) {
        final start = anchor < target ? anchor : target;
        final end = anchor > target ? anchor : target;
        next.addAll(
            visibleItems.sublist(start, end + 1).map((value) => value.path));
      }
    } else if (!next.add(item.path)) {
      next.remove(item.path);
    } else {
      _selectionAnchorPath = item.path;
    }
    if (next.isEmpty) {
      _isMultiSelectionMode = false;
      _selectionAnchorPath = null;
    }
    multiSelectedPathsListenable.value = Set<String>.unmodifiable(next);
    notifyListeners();
  }

  void selectAllItems(Iterable<FileItem> items) {
    _isMultiSelectionMode = true;
    multiSelectedPathsListenable.value =
        Set<String>.unmodifiable(items.map((item) => item.path).toSet());
    notifyListeners();
  }

  /// 用于桌面端拖拽框选，以一次状态更新替换当前可见项的选择结果。
  void replaceMultiSelection(Iterable<String> paths) {
    final next = Set<String>.unmodifiable(paths.toSet());
    _isMultiSelectionMode = next.isNotEmpty;
    _selectionAnchorPath = next.isEmpty ? null : next.last;
    multiSelectedPathsListenable.value = next;
    notifyListeners();
  }

  void clearMultiSelection() {
    _isMultiSelectionMode = false;
    _selectionAnchorPath = null;
    // 即使当前尚未选中条目，也必须发布一次空集合，令依赖该监听器的
    // 文件视图从选择模式重建回普通浏览模式。
    multiSelectedPathsListenable.value = Set<String>.unmodifiable(<String>{});
    notifyListeners();
  }

  /// 在当前目录的可见排序中移动当前项，不改变批量勾选状态。
  bool moveSelection(
    List<FileItem> visibleItems, {
    required int offset,
  }) {
    if (visibleItems.isEmpty || offset == 0) {
      return false;
    }

    final selectedPath = selectedItemListenable.value?.path;
    var currentIndex = visibleItems.indexWhere(
      (item) => item.path == selectedPath,
    );
    if (currentIndex < 0) {
      currentIndex = offset > 0 ? 0 : visibleItems.length - 1;
    }
    final targetIndex =
        (currentIndex + offset).clamp(0, visibleItems.length - 1);
    final target = visibleItems[targetIndex];

    clearMultiSelection();
    selectItem(target);
    return true;
  }
}
