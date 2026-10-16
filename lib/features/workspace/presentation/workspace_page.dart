import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/router/route_names.dart';
import '../../../core/utils/download_directory.dart';
import '../../../core/utils/file_size_formatter.dart';
import '../../../shared/path_utils.dart' as path_utils;
import '../../../shared/state/app_scope.dart';
import '../../../shared/state/app_services.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/file_sort_sheet.dart';
import '../../preview/domain/preview_type.dart';
import '../../preview/presentation/preview_page.dart';
import '../domain/delete_models.dart';
import '../domain/directory_summary.dart';
import '../domain/file_item.dart';
import '../domain/move_models.dart';
import '../domain/move_task_entry.dart';
import 'create_alias_dialog.dart';
import 'directory_picker_dialog.dart';
import 'widgets/batch_selection_bar.dart';
import 'widgets/delete_progress_banner.dart';
import 'widgets/empty_state.dart';
import 'widgets/move_progress_banner.dart';
import 'widgets/workspace_desktop_body.dart';
import 'widgets/workspace_grid_view.dart';
import 'widgets/workspace_list_view.dart';
import 'widgets/workspace_mobile_header.dart';

// 对外保留原有公开组件 API（recycle_bin_page 等仍从本文件引用）。
export 'widgets/workspace_desktop_body.dart';
export 'widgets/workspace_grid_view.dart';
export 'widgets/workspace_list_view.dart';
export 'widgets/workspace_mobile_header.dart';

part 'workspace_page_actions.dart';
part 'workspace_page_build.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key, this.desktopChrome = false});

  final bool desktopChrome;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

/// 打开系统文件选择器并将选中的一个或多个文件上传到当前目录。
///
/// 该入口同时供桌面标题栏和目录页按钮使用，确保两个按钮行为一致。
Future<void> pickAndUploadFile(
  BuildContext context, {
  bool fromAlbum = false,
}) async {
  final controller = AppScope.read(context);
  if (!controller.sessionController.capabilities.upload) {
    AppFeedback.showSnack(context, '当前身份没有上传权限');
    return;
  }

  try {
    final picked = await FilePicker.pickFiles(
      type: fromAlbum ? FileType.image : FileType.any,
    );
    if (picked.isEmpty) return;
    // 一次提交的多个文件归属同一批次，传输中心可展示整批上传汇总。
    final batchId = picked.length > 1
        ? 'batch-${DateTime.now().microsecondsSinceEpoch}'
        : null;
    for (final file in picked) {
      final localPath = file.path;
      if (localPath == null || localPath.isEmpty) {
        throw StateError('无法获取所选文件路径');
      }
      await controller.transferController.uploadFile(
        fileName: file.name,
        localPath: localPath,
        fileSize: (await file.length()) ?? 0,
        batchId: batchId,
      );
    }
    if (context.mounted) {
      AppFeedback.showSnack(context, '已创建 ${picked.length} 个文件的上传任务');
    }
  } catch (error) {
    if (context.mounted) {
      AppFeedback.showSnack(
        context,
        error.toString().replaceFirst('Bad state: ', ''),
      );
    }
  }
}

/// 选择本地文件夹，将其中内容按原有层级上传到当前目录。
Future<void> pickAndUploadDirectory(BuildContext context) async {
  final controller = AppScope.read(context);
  if (!controller.sessionController.capabilities.upload) {
    AppFeedback.showSnack(context, '当前身份没有上传权限');
    return;
  }

  try {
    final selectedPath = await FilePicker.getDirectoryPath(
      dialogTitle: '选择要上传的文件夹',
    );
    if (selectedPath == null || selectedPath.isEmpty) return;

    final directory = Directory(selectedPath);
    if (!await directory.exists()) {
      throw StateError('所选文件夹不存在或无法访问');
    }
    final rootPath = directory.path.replaceAll('\\', '/').replaceFirst(
          RegExp(r'/+$'),
          '',
        );
    final folderName = rootPath.split('/').last;
    final uploadRoot = controller.workspaceController.currentPath;
    if (folderName.isEmpty) throw StateError('无法获取文件夹名称');

    final entities =
        await directory.list(recursive: true, followLinks: false).toList();
    final folders = <String>[''];
    final files = <File>[];
    for (final entity in entities) {
      final entityPath = entity.path.replaceAll('\\', '/');
      if (!entityPath.startsWith('$rootPath/')) continue;
      final relativePath = entityPath.substring(rootPath.length + 1);
      if (entity is Directory) {
        folders.add(relativePath);
      } else if (entity is File) {
        files.add(entity);
      }
    }

    for (final relativePath in folders) {
      final name =
          relativePath.isEmpty ? folderName : '$folderName/$relativePath';
      await controller.workspaceController.createFolder(name, targetPath: uploadRoot);
    }
    // 整个文件夹作为一次提交归属同一批次。
    final batchId = files.length > 1
        ? 'batch-${DateTime.now().microsecondsSinceEpoch}'
        : null;
    for (final file in files) {
      final relativePath = file.path.replaceAll('\\', '/').substring(
            rootPath.length + 1,
          );
      final segments = relativePath.split('/');
      final fileName = segments.removeLast();
      final parent =
          segments.isEmpty ? folderName : '$folderName/${segments.join('/')}';
      await controller.transferController.uploadFile(
        fileName: fileName,
        localPath: file.path,
        fileSize: await file.length(),
        targetPath: '$uploadRoot$parent/',
        batchId: batchId,
      );
    }
    if (context.mounted) {
      AppFeedback.showSnack(context, '已创建 ${files.length} 个文件的上传任务');
    }
  } catch (error) {
    if (context.mounted) {
      AppFeedback.showSnack(
        context,
        error.toString().replaceFirst('Bad state: ', ''),
      );
    }
  }
}

class _WorkspacePageState extends State<WorkspacePage> {
  late Future<List<FileItem>> _itemsFuture;
  List<FileItem> _visibleItems = const <FileItem>[];
  final FocusNode _itemsFocusNode = FocusNode(
    debugLabel: 'workspace-items',
  );
  String? _boundPath;
  int? _boundTreeRevision;
  // 链接条目与真实条目可能共用同一路径，重命名需按 (path, isAlias) 匹配。
  // 删除期间用模态忙碌弹窗阻塞交互，防止同一批条目被重复提交删除。
  bool _deleteBusy = false;
  ({String path, bool isAlias})? _renamingTarget;
  bool _pendingMovesChecked = false;

  /// 子文件夹统计的异步回填值，按目录路径覆盖列表条目。
  Map<String, DirectorySummary> _summaryOverrides = const <String,
      DirectorySummary>{};

  /// 目录切换/手动刷新时递增，丢弃旧目录的统计回调。
  int _summaryGeneration = 0;

  /// 已启动统计回填的 _itemsFuture 实例，避免同一份列表重复触发。
  Object? _summaryFillKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_pendingMovesChecked) {
        _pendingMovesChecked = true;
        unawaited(_checkPendingMoves());
      }
    });
  }

  bool get _desktop =>
      widget.desktopChrome || MediaQuery.sizeOf(context).width >= 960;

  /// part 拆分出的扩展内不能直接调用受保护的 setState，经此桥接。
  void _setState(VoidCallback fn) => setState(fn);

  void _syncDirectoryBinding(AppServices controller, {bool force = false}) {
    if (!force &&
        _boundPath == controller.workspaceController.currentPath &&
        _boundTreeRevision == controller.workspaceController.treeRevision) {
      return;
    }
    _boundPath = controller.workspaceController.currentPath;
    _boundTreeRevision = controller.workspaceController.treeRevision;
    _itemsFuture = controller.workspaceController.listDirectory(controller.workspaceController.currentPath);
    _resetSummaryFill();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncDirectoryBinding(AppScope.of(context));
  }

  @override
  void dispose() {
    _itemsFocusNode.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final controller = AppScope.of(context);
    final future = controller.workspaceController.listDirectory(controller.workspaceController.currentPath);
    setState(() {
      _itemsFuture = future;
      _boundPath = controller.workspaceController.currentPath;
      _boundTreeRevision = controller.workspaceController.treeRevision;
      _resetSummaryFill();
    });
    await future;
  }

  Future<void> _openDirectory(String path) async {
    final controller = AppScope.of(context);
    controller.workspaceController.setCurrentPath(path);
    await _reload();
    if (mounted && _desktop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _itemsFocusNode.requestFocus();
        }
      });
    }
  }

  /// 进入虚拟目录别名；目标失效时提示且不切换目录。
  Future<void> _openAlias(FileItem item) async {
    final controller = AppScope.of(context);
    try {
      await controller.aliasController.openAlias(item);
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnack(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
      return;
    }
    await _reload();
  }

  Future<void> _goUp() async {
    final controller = AppScope.of(context);
    final target = controller.workspaceController.backNavigationPath();
    if (target == null) {
      return;
    }
    await _openDirectory(target);
  }

  void _openPreview(FileItem item) {
    final imageFiles = _visibleItems
        .where((file) =>
            !file.isDirectory &&
            PreviewTypeResolver.fromFileName(file.name) == PreviewType.image)
        .toList(growable: false);
    Navigator.of(context).pushNamed(
      RouteNames.preview,
      arguments: PreviewPageArguments(
        fileName: item.name,
        filePath: item.path,
        imageFiles: imageFiles,
      ),
    );
  }

  Future<void> _handleOpen(FileItem item) async {
    final controller = AppScope.of(context);
    controller.workspaceController.selectItem(item);
    if (item.isAlias) {
      await _openAlias(item);
      return;
    }
    if (item.isDirectory) {
      await _openDirectory(item.path);
      return;
    }
    _openPreview(item);
  }

  void _handleSelect(FileItem item) {
    AppScope.read(context).workspaceController.selectItem(item);
  }

  void _toggleMultiSelection(FileItem item, List<FileItem> items) {
    AppScope.read(context).workspaceController.toggleMultiSelection(
      item,
      visibleItems: items,
      range: HardwareKeyboard.instance.isShiftPressed,
    );
  }

  // State.build 必须在类体内覆写，构建逻辑拆分在 workspace_page_build.dart。
  @override
  Widget build(BuildContext context) => _buildScaffold(context);
}
