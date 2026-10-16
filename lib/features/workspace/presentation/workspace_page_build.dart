part of 'workspace_page.dart';

// _WorkspacePageState 的 build 构建与目录摘要辅助方法，私有成员经 part
// 与主文件共享。

extension _WorkspacePageBuild on _WorkspacePageState {
  void _resetSummaryFill() {
    _summaryGeneration++;
    _summaryOverrides = const <String, DirectorySummary>{};
    _summaryFillKey = null;
  }

  /// 目录列表展示后异步补齐子文件夹统计：先合并本地缓存命中值，再后台
  /// 受限并发刷新逐条回填；目录切换（generation 递增）后丢弃过期回调。
  void _fillSummaries(List<FileItem> items) {
    final controller = AppScope.of(context);
    final dirPaths = <String>[
      for (final item in items)
        if (item.isDirectory) item.path,
    ];
    if (dirPaths.isEmpty) return;
    final generation = _summaryGeneration;
    unawaited(() async {
      final cached = await controller.workspaceController.cachedDirectorySummaries(dirPaths);
      if (!mounted || generation != _summaryGeneration) return;
      if (cached.isNotEmpty) {
        _setState(() {
          _summaryOverrides = <String, DirectorySummary>{
            ..._summaryOverrides,
            ...cached,
          };
        });
      }
      await controller.workspaceController.refreshDirectorySummaries(
        dirPaths,
        onResult: (path, summary) {
          if (!mounted || generation != _summaryGeneration) return;
          _setState(() {
            _summaryOverrides = <String, DirectorySummary>{
              ..._summaryOverrides,
              path: summary,
            };
          });
        },
      );
    }());
  }

  void _ensureDefaultSelection(List<FileItem> items) {
    if (items.isEmpty) {
      return;
    }
    final controller = AppScope.read(context);
    final selected = controller.workspaceController.selectedItem;
    final stillVisible =
        selected != null && items.any((item) => item.path == selected.path);
    if (stillVisible) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final current = AppScope.read(context).workspaceController.selectedItem;
      final missing =
          current == null || !items.any((item) => item.path == current.path);
      if (missing) {
        AppScope.read(context).workspaceController.selectItem(items.first);
      }
    });
  }

  Widget _buildItemsArea({
    required AppServices controller,
    required bool desktop,
    required bool canUpload,
  }) {
    return FutureBuilder<List<FileItem>>(
      future: _itemsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text('目录加载失败'),
                const SizedBox(height: 8),
                Text(
                  '详细信息已写入调试日志',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13),
                ),
                const SizedBox(height: 12),
                FilledButton(onPressed: _reload, child: const Text('重试')),
              ],
            ),
          );
        }

        final baseItems = snapshot.data ?? const <FileItem>[];
        // 合并异步回填的子文件夹统计；列表顺序沿用列举排序，不受回填影响。
        final items = <FileItem>[
          for (final item in baseItems)
            if (item.isDirectory && _summaryOverrides[item.path] != null)
              item.copyWith(
                itemCount: _summaryOverrides[item.path]!.itemCount,
                updatedAt: _summaryOverrides[item.path]!.updatedAt,
              )
            else
              item,
        ];
        _visibleItems = items;
        if (_summaryFillKey != _itemsFuture) {
          _summaryFillKey = _itemsFuture;
          _fillSummaries(baseItems);
        }
        if (desktop) {
          _ensureDefaultSelection(items);
        }

        if (items.isEmpty) {
          return Listener(
            onPointerDown: (_) {
              if (desktop) {
                _itemsFocusNode.requestFocus();
              }
            },
            child: Focus(
              focusNode: _itemsFocusNode,
              onKeyEvent: (_, event) {
                if (desktop && event is KeyDownEvent) {
                  if (HardwareKeyboard.instance.isMetaPressed &&
                      event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    unawaited(_goUp());
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
                      event.logicalKey == LogicalKeyboardKey.arrowDown ||
                      event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                      event.logicalKey == LogicalKeyboardKey.arrowRight) {
                    return KeyEventResult.handled;
                  }
                }
                return KeyEventResult.ignored;
              },
              child: EmptyState(
                canUpload: canUpload,
                onAction: canUpload
                    ? (desktop
                        ? () => _pickUpload(fromAlbum: false)
                        : _showUploadSheet)
                    : null,
              ),
            ),
          );
        }

        return Listener(
          onPointerDown: (_) {
            if (desktop) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  _itemsFocusNode.requestFocus();
                }
              });
            }
          },
          child: Focus(
            key: const ValueKey<String>('workspace-items-focus'),
            focusNode: _itemsFocusNode,
            descendantsAreFocusable: _renamingTarget != null,
            onKeyEvent: (node, event) {
              if (desktop && event is KeyDownEvent) {
                if (event.logicalKey == LogicalKeyboardKey.escape &&
                    controller.workspaceController.isMultiSelectionMode) {
                  controller.workspaceController.clearMultiSelection();
                  return KeyEventResult.handled;
                }
                if (HardwareKeyboard.instance.isMetaPressed &&
                    event.logicalKey == LogicalKeyboardKey.keyA) {
                  controller.workspaceController.selectAllItems(items);
                  return KeyEventResult.handled;
                }
                if (HardwareKeyboard.instance.isMetaPressed) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    unawaited(_goUp());
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    final selected = controller.workspaceController.selectedItem;
                    if (selected != null) {
                      unawaited(_handleOpen(selected));
                    }
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                      event.logicalKey == LogicalKeyboardKey.arrowRight) {
                    return KeyEventResult.handled;
                  }
                }
                if (HardwareKeyboard.instance.isShiftPressed) {
                  return switch (event.logicalKey) {
                    LogicalKeyboardKey.arrowUp ||
                    LogicalKeyboardKey.arrowDown ||
                    LogicalKeyboardKey.arrowLeft ||
                    LogicalKeyboardKey.arrowRight =>
                      KeyEventResult.handled,
                    _ => KeyEventResult.ignored,
                  };
                }
                final isGrid = controller.workspaceController.browseMode == BrowseMode.grid;
                final offset = switch (event.logicalKey) {
                  LogicalKeyboardKey.arrowUp => isGrid
                      ? -_gridColumnCount(
                          node,
                          items.length,
                          controller.workspaceController.thumbnailSize,
                        )
                      : -1,
                  LogicalKeyboardKey.arrowDown => isGrid
                      ? _gridColumnCount(
                          node,
                          items.length,
                          controller.workspaceController.thumbnailSize,
                        )
                      : 1,
                  LogicalKeyboardKey.arrowLeft => isGrid ? -1 : 0,
                  LogicalKeyboardKey.arrowRight => isGrid ? 1 : 0,
                  _ => 0,
                };
                if (offset != 0 &&
                    controller.workspaceController.moveSelection(
                      items,
                      offset: offset,
                    )) {
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                    event.logicalKey == LogicalKeyboardKey.arrowRight) {
                  return KeyEventResult.handled;
                }
              }
              return KeyEventResult.ignored;
            },
            child: ValueListenableBuilder<Set<String>>(
              valueListenable: controller.workspaceController.multiSelectedPathsListenable,
              builder: (context, selectedPaths, _) {
                final selectedItems = items
                    .where((item) => selectedPaths.contains(item.path))
                    .toList(growable: false);
                final showBatchBar = desktop ||
                    selectedItems.isNotEmpty ||
                    controller.workspaceController.isMultiSelectionMode;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    ValueListenableBuilder<MoveProgress?>(
                      valueListenable: controller.moveController.moveStateListenable,
                      builder: (context, moveProgress, _) =>
                          moveProgress == null
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: MoveProgressBanner(
                                      progress: moveProgress),
                                ),
                    ),
                    ValueListenableBuilder<DeleteProgress?>(
                      valueListenable: controller.recycleBinController.deleteStateListenable,
                      builder: (context, deleteProgress, _) =>
                          deleteProgress == null
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: DeleteProgressBanner(
                                      progress: deleteProgress),
                                ),
                    ),
                    if (showBatchBar) ...<Widget>[
                      BatchSelectionBar(
                        selectedCount: selectedItems.length,
                        allSelected: selectedItems.length == items.length,
                        itemCount: items.length,
                        canDownload: controller.sessionController.capabilities.download,
                        canMove: controller.sessionController.capabilities.upload &&
                            controller.sessionController.capabilities.delete &&
                            !controller.moveController.isMoving,
                        canDelete: controller.sessionController.capabilities.delete,
                        onSelectAll: () {
                          if (selectedItems.length == items.length) {
                            controller.workspaceController.clearMultiSelection();
                          } else {
                            controller.workspaceController.selectAllItems(items);
                          }
                        },
                        onDownload: selectedItems.isEmpty
                            ? null
                            : () => _downloadSelected(selectedItems),
                        onMove: selectedItems.isEmpty
                            ? null
                            : () => _moveItems(selectedItems),
                        onDelete: selectedItems.isEmpty
                            ? null
                            : () => _deleteSelected(selectedItems),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Expanded(
                      child: ValueListenableBuilder<FileItem?>(
                        valueListenable: controller.workspaceController.selectedItemListenable,
                        builder: (context, selected, _) {
                          final selectedPath = selected?.path;
                          final selecting = controller.workspaceController.isMultiSelectionMode;
                          final isMultiSelectionMode =
                              controller.workspaceController.isMultiSelectionMode;
                          void onSelect(FileItem item) {
                            if (desktop) {
                              _itemsFocusNode.requestFocus();
                            }
                            if (isMultiSelectionMode) {
                              _toggleMultiSelection(item, items);
                            } else {
                              _handleSelect(item);
                            }
                          }

                          if (controller.workspaceController.browseMode == BrowseMode.grid) {
                            return WorkspaceGridView(
                              items: items,
                              selectedPath: selectedPath,
                              selectedPaths: selectedPaths,
                              multiSelecting: selecting,
                              desktop: desktop,
                              thumbnailSize: controller.workspaceController.thumbnailSize,
                              subtitleBuilder: _subtitle,
                              thumbnailLoader: controller.workspaceController.loadThumbnail,
                              thumbnailCacheNamespace:
                                  controller.workspaceController.thumbnailCacheNamespace,
                              onOpen: _handleOpen,
                              onMore: desktop ? (_) {} : _showItemActions,
                              onSelect: onSelect,
                              onToggle: (item) =>
                                  _toggleMultiSelection(item, items),
                              onMarqueeSelectionChanged:
                                  controller.workspaceController.replaceMultiSelection,
                              canUpload: canUpload,
                              canDelete: controller.sessionController.capabilities.delete,
                              canDownload: controller.sessionController.capabilities.download,
                              canMove: controller.sessionController.capabilities.upload &&
                                  controller.sessionController.capabilities.delete,
                              onDownload: _download,
                              onMove: (item) =>
                                  _moveItems(<FileItem>[item]),
                              onRename: _rename,
                              renamingTarget: _renamingTarget,
                              onRenameSubmit: _commitRename,
                              onRenameCancel: _cancelRename,
                              onDelete: _delete,
                              onCreateLink: _createLink,
                            );
                          }
                          return WorkspaceListView(
                            items: items,
                            desktop: desktop,
                            selectedPath: selectedPath,
                            selectedPaths: selectedPaths,
                            multiSelecting: selecting,
                            subtitleBuilder: _subtitle,
                            metaTimeBuilder: _metaTime,
                            canUpload: canUpload,
                            canDelete: controller.sessionController.capabilities.delete,
                            canDownload: controller.sessionController.capabilities.download,
                            canMove: controller.sessionController.capabilities.upload &&
                                controller.sessionController.capabilities.delete,
                            onOpen: _handleOpen,
                            onMore: desktop ? (_) {} : _showItemActions,
                            onSelect: onSelect,
                            onToggle: (item) =>
                                _toggleMultiSelection(item, items),
                            onMarqueeSelectionChanged:
                                controller.workspaceController.replaceMultiSelection,
                            onPreview: _openPreview,
                            onDownload: _download,
                            onMove: (item) => _moveItems(<FileItem>[item]),
                            onRename: _rename,
                            renamingTarget: _renamingTarget,
                            onRenameSubmit: _commitRename,
                            onRenameCancel: _cancelRename,
                            onDelete: _delete,
                            onCreateLink: _createLink,
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  int _gridColumnCount(
    FocusNode node,
    int itemCount,
    ThumbnailSize thumbnailSize,
  ) {
    final box = node.context?.findRenderObject() as RenderBox?;
    final width = box?.size.width;
    if (width == null || width <= 0) {
      return 1;
    }
    final maxCrossAxisExtent = thumbnailSize.maxCrossAxisExtent;
    const crossAxisSpacing = 12.0;
    final count =
        ((width + crossAxisSpacing) / (maxCrossAxisExtent + crossAxisSpacing))
            .ceil();
    return count.clamp(1, itemCount);
  }

  String _subtitle(FileItem item) {
    final parts = <String>[
      item.isDirectory && item.itemCount != null
          ? '${item.itemCount} 项'
          : item.typeLabel,
    ];
    if (!item.isDirectory) {
      parts.add(FileSizeFormatter.format(item.size ?? 0));
    }
    if (item.updatedAt != null) {
      final d = item.updatedAt!;
      final mm = d.month.toString().padLeft(2, '0');
      final dd = d.day.toString().padLeft(2, '0');
      final hh = d.hour.toString().padLeft(2, '0');
      final mi = d.minute.toString().padLeft(2, '0');
      parts.add('${d.year}-$mm-$dd $hh:$mi');
    }
    return parts.join(' · ');
  }

  String _metaTime(FileItem item) {
    if (item.updatedAt == null) {
      return '—';
    }
    final d = item.updatedAt!;
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd $hh:$mi';
  }

  // State.build 必须在 _WorkspacePageState 类体内覆写（见主文件），
  // 具体构建逻辑拆分在此，保持 build 部分聚焦构建与目录摘要。
  Widget _buildScaffold(BuildContext context) {
    final controller = AppScope.of(context);
    _syncDirectoryBinding(controller);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final desktop = _desktop;
    final canUpload = controller.sessionController.capabilities.upload;
    final canDelete = controller.sessionController.capabilities.delete;
    final canDownload = controller.sessionController.capabilities.download;

    // 移动端系统后退键由 HomeShell 统一拦截：非「文件」tab 先切回「文件」，
    // 「文件」tab 内非根目录返回上级，根目录才允许退出应用。
    return Scaffold(
      backgroundColor: desktop ? scheme.surface : theme.scaffoldBackgroundColor,
      floatingActionButton: desktop || !canUpload
          ? null
          : FloatingActionButton(
              onPressed: _showUploadSheet,
              child: const Icon(Icons.add),
            ),
      body: SafeArea(
        top: !desktop,
        child: desktop
            ? WorkspaceDesktopBody(
                path: controller.workspaceController.currentTitle,
                canGoUp: controller.workspaceController.backNavigationPath() != null,
                canUpload: canUpload,
                canDelete: canDelete,
                canDownload: canDownload,
                browseMode: controller.workspaceController.browseMode,
                thumbnailSize: controller.workspaceController.thumbnailSize,
                sortOption: controller.workspaceController.fileSortOption,
                selectedListenable: controller.workspaceController.selectedItemListenable,
                directorySizeStatesListenable:
                    controller.workspaceController.directorySizeStatesListenable,
                listArea: _buildItemsArea(
                  controller: controller,
                  desktop: true,
                  canUpload: canUpload,
                ),
                onGoUp: _goUp,
                onRefresh: _reload,
                onCreateFolder: _createFolder,
                onUpload: () => _pickUpload(fromAlbum: false),
                onUploadDirectory: _pickUploadDirectory,
                onBrowseModeChanged: controller.workspaceController.setBrowseMode,
                onThumbnailSizeChanged: controller.workspaceController.setThumbnailSize,
                onSortChanged: _setSortOption,
                onOpen: _handleOpen,
                onPreview: _openPreview,
                onDownload: _download,
                onDelete: _delete,
              )
            : Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    WorkspaceMobileHeader(
                      path: controller.workspaceController.currentTitle,
                      roleLabel: controller.sessionController.session?.displayName ?? '成员',
                      canGoUp: controller.workspaceController.backNavigationPath() != null,
                      browseMode: controller.workspaceController.browseMode,
                      sortOption: controller.workspaceController.fileSortOption,
                      onGoUp: _goUp,
                      onRefresh: _reload,
                      onBrowseModeChanged: controller.workspaceController.setBrowseMode,
                      onChooseSort: _showSortSheet,
                    ),
                    const SizedBox(height: 12),
                    if (!canUpload || !canDelete)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '当前用户缺少部分文件操作权限。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _buildItemsArea(
                        controller: controller,
                        desktop: false,
                        canUpload: canUpload,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
