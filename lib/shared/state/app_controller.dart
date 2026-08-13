import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/errors/app_error.dart';
import '../../features/auth/domain/user_session.dart';
import '../../features/auth/infrastructure/session_repository.dart';
import '../../features/transfer/domain/transfer_task.dart';
import '../../features/workspace/domain/file_item.dart';

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

/// In-memory mock app state. Mirrors docs/ui prototype behavior without backend.
class AppController extends ChangeNotifier {
  AppController({SessionRepository? sessionRepository})
      : _sessionRepository = sessionRepository ?? MemorySessionRepository();

  final SessionRepository _sessionRepository;

  static const rootPrefix = 'shared/';

  /// Selection updates only; does not rebuild the whole app shell.
  final ValueNotifier<FileItem?> selectedItemListenable =
      ValueNotifier<FileItem?>(null);

  /// Transfer task list/progress updates only; does not rebuild workspace.
  final ValueNotifier<List<TransferTask>> tasksListenable =
      ValueNotifier<List<TransferTask>>(_defaultTasks());

  UserSession? _session;
  String _currentPath = rootPrefix;
  BrowseMode _browseMode = BrowseMode.list;
  late Map<String, List<FileItem>> _tree = _defaultTree();
  List<ShareImportItem> _pendingShareItems = const <ShareImportItem>[];
  String _shareTargetPath = 'shared/photos/';
  bool _bootstrapped = false;
  int _taskSeq = 100;
  int _treeRevision = 0;

  final Map<String, Timer> _progressTimers = <String, Timer>{};

  UserSession? get session => _session;
  bool get isLoggedIn => _session != null;
  String get currentPath => _currentPath;
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
        _currentPath = restored.rootPrefix.isEmpty ? rootPrefix : restored.rootPrefix;
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
      _currentPath = session.rootPrefix.isEmpty ? rootPrefix : session.rootPrefix;
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

  Future<List<FileItem>> listDirectory([String? path]) async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final target = path ?? _currentPath;
    final items = List<FileItem>.from(_tree[target] ?? const <FileItem>[]);
    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
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
    final items = List<FileItem>.from(_tree[dir] ?? const <FileItem>[]);
    if (items.any((item) => item.name == folderName)) {
      throw StateError('同名项已存在');
    }
    items.add(
      FileItem(
        path: path,
        name: folderName,
        isDirectory: true,
        updatedAt: DateTime.now(),
      ),
    );
    _tree[dir] = items;
    _tree.putIfAbsent(path, () => <FileItem>[]);
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

    final parent = item.isDirectory ? parentPath(item.path) : parentPath(item.path);
    final dir = _normalizeDir(parent == item.path ? rootPrefix : parent);
    final items = List<FileItem>.from(_tree[dir] ?? const <FileItem>[]);
    final index = items.indexWhere((e) => e.path == item.path);
    if (index < 0) {
      throw StateError('未找到目标项');
    }
    if (items.any((e) => e.name == trimmed && e.path != item.path)) {
      throw StateError('同名项已存在');
    }

    final newPath = item.isDirectory ? '$dir$trimmed/' : '$dir$trimmed';
    final updated = item.copyWith(name: trimmed, path: newPath, updatedAt: DateTime.now());
    items[index] = updated;
    _tree[dir] = items;

    if (item.isDirectory) {
      final oldPrefix = item.path;
      final moved = <String, List<FileItem>>{};
      for (final entry in _tree.entries) {
        if (entry.key == oldPrefix || entry.key.startsWith(oldPrefix)) {
          final suffix = entry.key.substring(oldPrefix.length);
          final nextKey = '$newPath$suffix';
          moved[nextKey] = entry.value
              .map(
                (child) => child.copyWith(
                  path: child.path.replaceFirst(oldPrefix, newPath),
                ),
              )
              .toList();
        }
      }
      _tree.removeWhere((key, _) => key == oldPrefix || key.startsWith(oldPrefix));
      _tree.addAll(moved);
    }

    if (selectedItemListenable.value?.path == item.path) {
      selectedItemListenable.value = updated;
    }
    _treeRevision++;
    notifyListeners();
  }

  Future<void> deleteItem(FileItem item) async {
    _ensureDeleteCapability();
    final dir = item.isDirectory ? parentPath(item.path) : parentPath(item.path);
    final parent = _normalizeDir(dir);
    final items = List<FileItem>.from(_tree[parent] ?? const <FileItem>[]);
    items.removeWhere((e) => e.path == item.path);
    _tree[parent] = items;
    _treeRevision++;

    if (item.isDirectory) {
      _tree.removeWhere((key, _) => key == item.path || key.startsWith(item.path));
    }
    if (selectedItemListenable.value?.path == item.path) {
      selectedItemListenable.value = null;
    }
    notifyListeners();
  }

  Future<void> mockUpload({
    required String fileName,
    int size = 1024 * 512,
    String? targetPath,
  }) async {
    _ensureUploadCapability();
    final dir = _normalizeDir(targetPath ?? _currentPath);
    _tree.putIfAbsent(dir, () => <FileItem>[]);

    final path = '$dir$fileName';
    final items = List<FileItem>.from(_tree[dir]!);
    items.removeWhere((e) => e.path == path);
    items.add(
      FileItem(
        path: path,
        name: fileName,
        isDirectory: false,
        size: size,
        updatedAt: DateTime.now(),
      ),
    );
    _tree[dir] = items;
    _treeRevision++;

    final task = TransferTask(
      id: 'task-${++_taskSeq}',
      name: fileName,
      type: TransferTaskType.upload,
      status: TransferTaskStatus.running,
      progress: 0.08,
      message: '正在上传到 $dir',
      target: dir,
    );
    _setTasks(<TransferTask>[task, ...tasksListenable.value]);
    notifyListeners();
    _simulateProgress(task.id, successMessage: '上传完成');
  }

  Future<void> mockDownload(FileItem item) async {
    if (!capabilities.download) {
      throw StateError('当前身份没有下载权限');
    }
    if (item.isDirectory) {
      throw StateError('一期不支持文件夹下载');
    }

    final task = TransferTask(
      id: 'task-${++_taskSeq}',
      name: item.name,
      type: TransferTaskType.download,
      status: TransferTaskStatus.running,
      progress: 0.12,
      message: '保存到本地下载目录',
      target: '本地下载目录',
    );
    _setTasks(<TransferTask>[task, ...tasksListenable.value]);
    _simulateProgress(task.id, successMessage: '已保存到下载目录');
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
    _simulateProgress(taskId, successMessage: task.type == TransferTaskType.upload ? '上传完成' : '下载完成');
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
    _pendingShareItems =
        _pendingShareItems.where((item) => item.id != id).toList(growable: false);
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
    final items = List<ShareImportItem>.from(_pendingShareItems);
    _pendingShareItems = const <ShareImportItem>[];
    notifyListeners();

    for (final item in items) {
      await mockUpload(
        fileName: item.name,
        size: item.size,
        targetPath: _shareTargetPath,
      );
    }
  }

  String mockPreviewText(String fileName) {
    return "文件：$fileName\n\n当前为文本预览内容。";
  }

  List<String> get sidebarDirectories {
    // 侧栏仅展示 shared/ 及其一级子目录。
    final dirs = _tree.keys.where((path) {
      if (path == rootPrefix) {
        return true;
      }
      if (!path.startsWith(rootPrefix)) {
        return false;
      }
      final rest = path.substring(rootPrefix.length);
      if (rest.isEmpty) {
        return false;
      }
      final slash = rest.indexOf('/');
      return slash == rest.length - 1;
    }).toList()
      ..sort((a, b) => a.compareTo(b));
    return dirs;
  }

  void _resumeRunningTasks() {
    for (final task in tasksListenable.value) {
      if (task.status == TransferTaskStatus.running) {
        _simulateProgress(
          task.id,
          successMessage: task.type == TransferTaskType.upload ? '上传完成' : '下载完成',
        );
      }
    }
  }

  void _simulateProgress(String taskId, {required String successMessage}) {
    if (_progressTimers.containsKey(taskId)) {
      return;
    }
    _progressTimers.remove(taskId)?.cancel();
    _progressTimers[taskId] = Timer.periodic(const Duration(milliseconds: 350), (timer) {
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

  static Map<String, List<FileItem>> _defaultTree() {
    DateTime d(int month, int day, [int hour = 10, int minute = 0]) =>
        DateTime(2026, month, day, hour, minute);

    return <String, List<FileItem>>{
      'shared/': <FileItem>[
        FileItem(path: 'shared/common/', name: 'common', isDirectory: true, updatedAt: d(6, 1)),
        FileItem(path: 'shared/photos/', name: 'photos', isDirectory: true, updatedAt: d(6, 2, 9, 30)),
        FileItem(path: 'shared/docs/', name: 'docs', isDirectory: true, updatedAt: d(6, 3, 14, 20)),
        FileItem(path: 'shared/uploads/', name: 'uploads', isDirectory: true, updatedAt: d(6, 5, 9)),
        FileItem(
          path: 'shared/家庭合影.jpg',
          name: '家庭合影.jpg',
          isDirectory: false,
          size: 2516582,
          updatedAt: d(6, 5, 9, 12),
        ),
        FileItem(
          path: 'shared/家庭档案说明.pdf',
          name: '家庭档案说明.pdf',
          isDirectory: false,
          size: 880640,
          updatedAt: d(6, 4, 18),
        ),
        FileItem(
          path: 'shared/readme.txt',
          name: 'readme.txt',
          isDirectory: false,
          size: 4096,
          updatedAt: d(6, 2, 8, 45),
        ),
      ],
      'shared/common/': <FileItem>[
        FileItem(
          path: 'shared/common/family-rules.pdf',
          name: 'family-rules.pdf',
          isDirectory: false,
          size: 248320,
          updatedAt: d(5, 28, 19, 10),
        ),
        FileItem(
          path: 'shared/common/receipts/',
          name: 'receipts',
          isDirectory: true,
          updatedAt: d(6, 1, 11),
        ),
        FileItem(
          path: 'shared/common/access-guide.txt',
          name: 'access-guide.txt',
          isDirectory: false,
          size: 4096,
          updatedAt: d(6, 1, 18, 20),
        ),
      ],
      'shared/common/receipts/': <FileItem>[
        FileItem(
          path: 'shared/common/receipts/2026-05.pdf',
          name: '2026-05.pdf',
          isDirectory: false,
          size: 156000,
          updatedAt: d(5, 31, 20, 15),
        ),
        FileItem(
          path: 'shared/common/receipts/2026-06.pdf',
          name: '2026-06.pdf',
          isDirectory: false,
          size: 168400,
          updatedAt: d(6, 3, 20, 15),
        ),
      ],
      'shared/photos/': <FileItem>[
        FileItem(
          path: 'shared/photos/2026-trip.jpg',
          name: '2026-trip.jpg',
          isDirectory: false,
          size: 3145728,
          updatedAt: d(6, 5, 17, 12),
        ),
        FileItem(
          path: 'shared/photos/beach.png',
          name: 'beach.png',
          isDirectory: false,
          size: 1843200,
          updatedAt: d(6, 5, 16),
        ),
        FileItem(
          path: 'shared/photos/dinner.jpg',
          name: 'dinner.jpg',
          isDirectory: false,
          size: 2237440,
          updatedAt: d(6, 4, 20),
        ),
        FileItem(
          path: 'shared/photos/notes.txt',
          name: 'notes.txt',
          isDirectory: false,
          size: 2048,
          updatedAt: d(6, 4, 15),
        ),
        FileItem(
          path: 'shared/photos/album-guide.pdf',
          name: 'album-guide.pdf',
          isDirectory: false,
          size: 120400,
          updatedAt: d(6, 3, 11),
        ),
        FileItem(
          path: 'shared/photos/portraits/',
          name: 'portraits',
          isDirectory: true,
          updatedAt: d(6, 5, 17),
        ),
      ],
      'shared/photos/portraits/': <FileItem>[
        FileItem(
          path: 'shared/photos/portraits/alice.png',
          name: 'alice.png',
          isDirectory: false,
          size: 1245728,
          updatedAt: d(6, 5, 17, 6),
        ),
        FileItem(
          path: 'shared/photos/portraits/bob.jpg',
          name: 'bob.jpg',
          isDirectory: false,
          size: 1457280,
          updatedAt: d(6, 5, 17, 8),
        ),
      ],
      'shared/docs/': <FileItem>[
        FileItem(
          path: 'shared/docs/project-plan.md',
          name: 'project-plan.md',
          isDirectory: false,
          size: 8192,
          updatedAt: d(6, 3, 21, 5),
        ),
        FileItem(
          path: 'shared/docs/server-config.json',
          name: 'server-config.json',
          isDirectory: false,
          size: 3072,
          updatedAt: d(6, 2, 16, 40),
        ),
      ],
      'shared/uploads/': <FileItem>[],
    };
  }

  static List<TransferTask> _defaultTasks() {
    return <TransferTask>[];
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
