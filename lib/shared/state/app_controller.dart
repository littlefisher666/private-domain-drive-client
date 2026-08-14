import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../core/errors/app_error.dart';
import '../../features/auth/domain/user_session.dart';
import '../../features/auth/infrastructure/session_repository.dart';
import '../../features/transfer/domain/transfer_task.dart';
import '../../features/workspace/domain/file_item.dart';
import '../../features/workspace/infrastructure/oss_client.dart';

class ShareImportItem {
  const ShareImportItem({
    required this.id,
    required this.name,
    required this.size,
  });

  final String id;
  final String name;
  final int size;
}

class LoginResult {
  const LoginResult.success(this.session)
      : ok = true,
        message = null;

  const LoginResult.failure(this.message)
      : ok = false,
        session = null;

  final bool ok;
  final String? message;
  final UserSession? session;
}

/// 应用状态控制器。会话与权限来自已部署的 FC，不在生产路径伪造身份。
class AppController extends ChangeNotifier {
  AppController(
      {required SessionRepository sessionRepository, OssClient? ossClient})
      : _sessionRepository = sessionRepository,
        _ossClient = ossClient ?? OssClient();

  final SessionRepository _sessionRepository;
  final OssClient _ossClient;

  static const rootPrefix = 'shared/';

  /// Selection updates only; does not rebuild the whole app shell.
  final ValueNotifier<FileItem?> selectedItemListenable =
      ValueNotifier<FileItem?>(null);

  /// Transfer task list/progress updates only; does not rebuild workspace.
  final ValueNotifier<List<TransferTask>> tasksListenable =
      ValueNotifier<List<TransferTask>>(<TransferTask>[]);

  UserSession? _session;
  String _currentPath = rootPrefix;
  BrowseMode _browseMode = BrowseMode.list;
  final Set<String> _remoteDirectories = <String>{};
  List<ShareImportItem> _pendingShareItems = const <ShareImportItem>[];
  String _shareTargetPath = 'shared/photos/';
  bool _bootstrapped = false;
  int _treeRevision = 0;

  final Map<String, Timer> _progressTimers = <String, Timer>{};

  UserSession? get session => _session;
  bool get isLoggedIn => _session != null;
  String get currentPath => _currentPath;

  /// 将 OSS 内部对象键转换为用户可见的相对路径。
  String displayPath(String path) {
    final normalized = path.trim();
    final root = _session?.rootPrefix.isNotEmpty == true
        ? _normalizeDir(_session!.rootPrefix)
        : rootPrefix;
    if (normalized.isEmpty || normalized == root) {
      return '全部文件';
    }
    final relative = normalized.startsWith(root)
        ? normalized.substring(root.length)
        : normalized;
    return relative.replaceFirst(RegExp(r'/$'), '').isEmpty
        ? '全部文件'
        : relative.replaceFirst(RegExp(r'/$'), '');
  }

  BrowseMode get browseMode => _browseMode;
  List<TransferTask> get tasks => tasksListenable.value;
  List<ShareImportItem> get pendingShareItems =>
      List<ShareImportItem>.unmodifiable(_pendingShareItems);
  String get shareTargetPath => _shareTargetPath;
  FileItem? get selectedItem => selectedItemListenable.value;
  bool get bootstrapped => _bootstrapped;
  int get treeRevision => _treeRevision;
  Capabilities get capabilities =>
      _session?.capabilities ?? const Capabilities.member();

  Future<void> bootstrap() async {
    try {
      final restored = await _sessionRepository.restore();
      if (restored != null) {
        _session = restored;
        _currentPath =
            restored.rootPrefix.isEmpty ? rootPrefix : restored.rootPrefix;
        _resumeRunningTasks();
      }
    } catch (_) {
      // Keep app usable even if secure storage restore fails.
    }
    _bootstrapped = true;
    notifyListeners();
  }

  Future<LoginResult> login({
    required String account,
    required String password,
  }) async {
    try {
      final session = await _sessionRepository.login(
        account: account,
        password: password,
      );
      _session = session;
      _currentPath =
          session.rootPrefix.isEmpty ? rootPrefix : session.rootPrefix;
      selectedItemListenable.value = null;
      _resumeRunningTasks();
      notifyListeners();
      return LoginResult.success(session);
    } on AppError catch (error) {
      return LoginResult.failure(error.message);
    } catch (error) {
      return LoginResult.failure(error.toString());
    }
  }

  Future<void> logout() async {
    await _sessionRepository.logout();
    _session = null;
    _remoteDirectories.clear();
    selectedItemListenable.value = null;
    _pendingShareItems = const <ShareImportItem>[];
    for (final timer in _progressTimers.values) {
      timer.cancel();
    }
    _progressTimers.clear();
    notifyListeners();
  }

  Future<void> ensureFreshCredentials() async {
    final session = _session;
    if (session == null || !session.isRemote) {
      return;
    }
    final credentials = session.credentials;
    if (credentials != null &&
        credentials.isValid(skew: const Duration(minutes: 8))) {
      return;
    }
    final refreshed = await _sessionRepository.refreshCredentials(session);
    _session = refreshed;
    notifyListeners();
  }

  UserSession _requireSession() {
    final session = _session;
    if (session == null || !session.isRemote || session.credentials == null) {
      throw AppError('请先登录服务端账号', code: 'REMOTE_SESSION_REQUIRED');
    }
    return session;
  }

  Future<List<FileItem>> listDirectory([String? path]) async {
    final session = _session;
    if (session == null || !session.isRemote || session.credentials == null) {
      throw AppError('请先登录服务端账号', code: 'REMOTE_SESSION_REQUIRED');
    }
    await ensureFreshCredentials();
    final items = await _ossClient.list(path ?? _currentPath, _session!);
    if ((path ?? _currentPath) == _currentPath) {
      final beforeCount = _remoteDirectories.length;
      _remoteDirectories
        ..add(_currentPath)
        ..addAll(
            items.where((item) => item.isDirectory).map((item) => item.path));
      if (_remoteDirectories.length != beforeCount) {
        notifyListeners();
      }
    }
    return items;
  }

  void setCurrentPath(String path) {
    _currentPath = _normalizeDir(path);
    selectedItemListenable.value = null;
    notifyListeners();
  }

  void setBrowseMode(BrowseMode mode) {
    if (_browseMode == mode) {
      return;
    }
    _browseMode = mode;
    notifyListeners();
  }

  void selectItem(FileItem? item) {
    final current = selectedItemListenable.value;
    if (current?.path == item?.path &&
        current?.name == item?.name &&
        current?.isDirectory == item?.isDirectory) {
      // Keep object fresh for rename/metadata without extra noise when identical.
      if (!identical(current, item)) {
        selectedItemListenable.value = item;
      }
      return;
    }
    selectedItemListenable.value = item;
  }

  String parentPath(String path) {
    final normalized = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final idx = normalized.lastIndexOf('/');
    if (idx <= 0) {
      return rootPrefix;
    }
    return normalized.substring(0, idx + 1);
  }

  Future<void> createFolder(String name) async {
    _ensureUploadCapability();
    final folderName = name.trim();
    if (folderName.isEmpty) {
      throw StateError('文件夹名称不能为空');
    }
    final dir = _normalizeDir(_currentPath);
    final path = '$dir$folderName/';
    await ensureFreshCredentials();
    await _ossClient.createFolder(path, _requireSession());
    _treeRevision++;
    notifyListeners();
  }

  Future<void> renameItem(FileItem item, String newName) async {
    _ensureDeleteCapability(); // rename treated as write capability with delete/upload
    if (!capabilities.upload && !capabilities.delete) {
      throw StateError('当前身份没有重命名权限');
    }
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      throw StateError('名称不能为空');
    }

    final parent =
        item.isDirectory ? parentPath(item.path) : parentPath(item.path);
    final dir = _normalizeDir(parent == item.path ? rootPrefix : parent);
    final newPath = item.isDirectory ? '$dir$trimmed/' : '$dir$trimmed';
    await ensureFreshCredentials();
    final session = _requireSession();
    await _ossClient.copy(item.path, newPath, session);
    await _ossClient.delete(item.path, session);
    _treeRevision++;
    notifyListeners();
  }

  Future<void> deleteItem(FileItem item) async {
    _ensureDeleteCapability();
    await ensureFreshCredentials();
    final session = _requireSession();
    if (item.isDirectory) {
      await _deleteDirectoryRecursively(item.path, session);
      final deletedPath = _normalizeDir(item.path);
      _remoteDirectories.removeWhere(
        (path) => path == deletedPath || path.startsWith(deletedPath),
      );
      if (_currentPath.startsWith(deletedPath)) {
        _currentPath = parentPath(deletedPath);
      }
    } else {
      await _ossClient.delete(item.path, session);
    }
    _treeRevision++;

    if (selectedItemListenable.value?.path == item.path) {
      selectedItemListenable.value = null;
    }
    notifyListeners();
  }

  Future<void> _deleteDirectoryRecursively(
    String path,
    UserSession session,
  ) async {
    final children = await _ossClient.list(path, session);
    for (final child in children) {
      if (child.isDirectory) {
        await _deleteDirectoryRecursively(child.path, session);
      } else {
        await _ossClient.delete(child.path, session);
      }
    }
    await _ossClient.delete(path, session);
  }

  Future<void> uploadBytes(
      {required String fileName,
      required List<int> bytes,
      String? targetPath}) async {
    _ensureUploadCapability();
    await ensureFreshCredentials();
    final dir = _normalizeDir(targetPath ?? _currentPath);
    await _ossClient.upload('$dir$fileName', bytes, _requireSession());
    _treeRevision++;
    notifyListeners();
  }

  Future<List<int>> downloadBytes(FileItem item) async {
    if (!capabilities.download) {
      throw StateError('当前身份没有下载权限');
    }
    if (item.isDirectory) {
      throw StateError('一期不支持文件夹下载');
    }

    await ensureFreshCredentials();
    return _ossClient.download(item.path, _requireSession());
  }

  void retryTask(String taskId) {
    final current = List<TransferTask>.from(tasksListenable.value);
    final index = current.indexWhere((task) => task.id == taskId);
    if (index < 0) {
      return;
    }
    final task = current[index];
    if (task.status != TransferTaskStatus.failed &&
        task.status != TransferTaskStatus.canceled) {
      return;
    }
    final next = task.copyWith(
      status: TransferTaskStatus.running,
      progress: 0.1,
      message: '重新开始',
    );
    current[index] = next;
    _setTasks(current);
    _simulateProgress(taskId,
        successMessage: task.type == TransferTaskType.upload ? '上传完成' : '下载完成');
  }

  void cancelTask(String taskId) {
    _progressTimers.remove(taskId)?.cancel();
    final current = List<TransferTask>.from(tasksListenable.value);
    final index = current.indexWhere((task) => task.id == taskId);
    if (index < 0) {
      return;
    }
    final task = current[index];
    if (task.status != TransferTaskStatus.running &&
        task.status != TransferTaskStatus.pending) {
      return;
    }
    current[index] = task.copyWith(
      status: TransferTaskStatus.canceled,
      message: '已取消',
    );
    _setTasks(current);
  }

  void clearCompletedTasks() {
    _setTasks(
      tasksListenable.value
          .where(
            (task) =>
                task.status != TransferTaskStatus.success &&
                task.status != TransferTaskStatus.canceled,
          )
          .toList(),
    );
  }

  void prepareShareImport({List<ShareImportItem>? items, String? targetPath}) {
    _pendingShareItems = List<ShareImportItem>.unmodifiable(
      items ?? const <ShareImportItem>[],
    );
    _shareTargetPath = _normalizeDir(targetPath ?? 'shared/photos/');
    notifyListeners();
  }

  void removeShareItem(String id) {
    _pendingShareItems = _pendingShareItems
        .where((item) => item.id != id)
        .toList(growable: false);
    notifyListeners();
  }

  void setShareTargetPath(String path) {
    _shareTargetPath = _normalizeDir(path);
    notifyListeners();
  }

  Future<void> confirmShareUpload() async {
    _ensureUploadCapability();
    if (_pendingShareItems.isEmpty) {
      throw StateError('没有待上传内容');
    }
    _pendingShareItems = const <ShareImportItem>[];
    notifyListeners();

    throw StateError('分享导入缺少原始文件内容，无法直接上传 OSS');
  }

  List<String> get sidebarDirectories {
    if (_session?.isRemote == true) {
      final root = _normalizeDir(_session?.rootPrefix ?? rootPrefix);
      final dirs = _remoteDirectories.where((path) {
        if (!path.startsWith(root)) return false;
        final rest = path.substring(root.length);
        return rest.isNotEmpty && rest.indexOf('/') == rest.length - 1;
      }).toList()
        ..sort();
      return List<String>.unmodifiable(dirs);
    }
    return const <String>[];
  }

  void _resumeRunningTasks() {
    for (final task in tasksListenable.value) {
      if (task.status == TransferTaskStatus.running) {
        _simulateProgress(
          task.id,
          successMessage:
              task.type == TransferTaskType.upload ? '上传完成' : '下载完成',
        );
      }
    }
  }

  void _simulateProgress(String taskId, {required String successMessage}) {
    if (_progressTimers.containsKey(taskId)) {
      return;
    }
    _progressTimers.remove(taskId)?.cancel();
    _progressTimers[taskId] =
        Timer.periodic(const Duration(milliseconds: 350), (timer) {
      final current = List<TransferTask>.from(tasksListenable.value);
      final index = current.indexWhere((task) => task.id == taskId);
      if (index < 0) {
        timer.cancel();
        _progressTimers.remove(taskId);
        return;
      }
      final task = current[index];
      if (task.status != TransferTaskStatus.running) {
        timer.cancel();
        _progressTimers.remove(taskId);
        return;
      }

      final nextProgress = (task.progress + 0.14).clamp(0.0, 1.0);
      if (nextProgress >= 1) {
        current[index] = task.copyWith(
          progress: 1,
          status: TransferTaskStatus.success,
          message: successMessage,
        );
        timer.cancel();
        _progressTimers.remove(taskId);
      } else {
        current[index] = task.copyWith(
          progress: nextProgress,
          message: '进行中 · ${(nextProgress * 100).round()}%',
        );
      }
      _setTasks(current);
    });
  }

  void _setTasks(List<TransferTask> next) {
    tasksListenable.value = List<TransferTask>.unmodifiable(next);
  }

  void _ensureUploadCapability() {
    if (!capabilities.upload) {
      throw StateError('当前身份没有上传权限');
    }
  }

  void _ensureDeleteCapability() {
    if (!capabilities.delete) {
      throw StateError('当前身份没有删除权限');
    }
  }

  String _normalizeDir(String path) {
    if (path.isEmpty) {
      return rootPrefix;
    }
    return path.endsWith('/') ? path : '$path/';
  }

  @override
  void dispose() {
    for (final timer in _progressTimers.values) {
      timer.cancel();
    }
    _progressTimers.clear();
    selectedItemListenable.dispose();
    tasksListenable.dispose();
    super.dispose();
  }
}
