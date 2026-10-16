import 'package:flutter/foundation.dart';

import '../../../core/errors/app_error.dart';
import '../../../shared/path_utils.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/user_session.dart';
import '../domain/directory_alias.dart';
import '../domain/file_item.dart';
import '../infrastructure/alias_repository.dart';
import '../infrastructure/oss_client.dart';
import 'workspace_controller.dart';

/// 别名域的编排层：虚拟目录别名的打开导航、创建、删除与重命名，
/// 以及别名表的读-改-写与名称冲突校验。
///
/// 别名表状态由 [WorkspaceController] 持有并供目录浏览挂载读取；本控制器
/// 经 [AliasRepository] 完成持久化写入后回写工作区缓存，树版本、目录
/// 大小缓存与通知时机由各操作按既有语义决定。
class AliasController extends ChangeNotifier {
  AliasController({
    required SessionController sessionController,
    required WorkspaceController workspaceController,
    required AliasRepository aliasRepository,
    required OssClient ossClient,
  })  : _sessionController = sessionController,
        _workspaceController = workspaceController,
        _aliasRepository = aliasRepository,
        _ossClient = ossClient;

  final SessionController _sessionController;
  final WorkspaceController _workspaceController;
  final AliasRepository _aliasRepository;
  final OssClient _ossClient;

  String _normalizeDir(String path) => normalizeDirPath(path);

  UserSession _requireSession() => _sessionController.requireSession();

  /// 进入虚拟目录别名：此后浏览、上传、下载、删除、移动等操作均作用于
  /// 别名的真实目标前缀。目标已失效（前缀下无任何对象）时抛出明确错误，
  /// 不展示空目录成功态。
  Future<void> openAlias(FileItem alias) async {
    if (!alias.isAlias || alias.aliasId == null) {
      throw StateError('条目不是目录别名');
    }
    final session = _requireSession();
    await _sessionController.ensureSessionReady();
    final target = _normalizeDir(alias.path);
    if (!await _ossClient.directoryExists(target, session)) {
      throw AppError(
        '目标目录不存在，链接可能已失效',
        code: 'ALIAS_TARGET_MISSING',
      );
    }
    final origin = _normalizeDir(_workspaceController.currentPath);
    final root = _normalizeDir(_workspaceController.workspaceRoot);
    // 后退返回进入别名前所在的层级，即其挂载层级。
    _workspaceController.enterAliasTarget(
      targetPrefix: target,
      aliasName: alias.name,
      returnPath: origin.startsWith(root) && origin != target ? origin : null,
    );
  }

  /// 为真实文件夹条目创建指向它的目录别名，挂载到 [parentPrefix] 层级。
  Future<void> createAlias(
    FileItem targetFolder,
    String name, {
    required String parentPrefix,
  }) async {
    _sessionController.ensureUploadCapability();
    final session = _requireSession();
    await _sessionController.ensureSessionReady();
    final target = _normalizeDir(targetFolder.path);
    final root = _normalizeDir(_workspaceController.workspaceRoot);
    final parent = _normalizeDir(parentPrefix);
    if (target == root) {
      throw StateError('不能为根目录创建链接');
    }
    if (!parent.startsWith(root)) {
      throw StateError('挂载位置不在网盘范围内');
    }
    final aliasName = name.trim();
    await _validateAliasName(
      aliasName,
      session,
      parentPrefix: parent,
    );
    if (!await _ossClient.directoryExists(target, session)) {
      throw AppError('目标目录不存在，无法创建链接', code: 'ALIAS_TARGET_MISSING');
    }
    final alias = DirectoryAlias.create(
      name: aliasName,
      targetPrefix: target,
      parentPrefix: parent,
      createdBy: session.displayName.isNotEmpty == true
          ? session.displayName
          : session.account,
    );
    final table = await _aliasRepository.update(
      session,
      (table) => table.copyWith(aliases: [...table.aliases, alias]),
    );
    _workspaceController.adoptAliasTable(table);
    _workspaceController.bumpTreeRevision();
    _workspaceController.clearDirectorySizeCache();
    notifyListeners();
  }

  /// 删除链接：仅从别名表移除条目，不影响目标目录内容。
  Future<void> deleteAlias(FileItem aliasItem) async {
    _sessionController.ensureDeleteCapability();
    final id = aliasItem.aliasId;
    if (!aliasItem.isAlias || id == null) {
      throw StateError('条目不是目录别名');
    }
    final session = _requireSession();
    await _sessionController.ensureSessionReady();
    final table = await _aliasRepository.update(
      session,
      (table) => table.copyWith(
        aliases:
            table.aliases.where((alias) => alias.id != id).toList(),
      ),
    );
    _workspaceController.adoptAliasTable(table);
    _workspaceController.bumpTreeRevision();
    notifyListeners();
  }

  /// 重命名链接：仅修改别名表中的展示名称。
  Future<void> renameAlias(FileItem aliasItem, String newName) async {
    _sessionController.ensureUploadCapability();
    final id = aliasItem.aliasId;
    if (!aliasItem.isAlias || id == null) {
      throw StateError('条目不是目录别名');
    }
    final session = _requireSession();
    await _sessionController.ensureSessionReady();
    final existing = _workspaceController.aliasTable.byId(id);
    if (existing == null) {
      throw StateError('别名条目不存在');
    }
    final aliasName = newName.trim();
    await _validateAliasName(
      aliasName,
      session,
      parentPrefix: existing.parentPrefix,
      excludeAliasId: id,
    );
    final table = await _aliasRepository.update(
      session,
      (table) => table.copyWith(
        aliases: <DirectoryAlias>[
          for (final alias in table.aliases)
            if (alias.id == id) alias.copyWith(name: aliasName) else alias,
        ],
      ),
    );
    _workspaceController.adoptAliasTable(table);
    _workspaceController.renameActiveAlias(aliasItem.name, aliasName);
    _workspaceController.bumpTreeRevision();
    notifyListeners();
  }

  /// 校验别名名称：非空、不以点开头、不含 `/`，且不与挂载层级
  /// [parentPrefix] 现有真实条目或同级别名重名（忽略大小写）。
  Future<void> _validateAliasName(
    String name,
    UserSession session, {
    required String parentPrefix,
    String? excludeAliasId,
  }) async {
    if (name.isEmpty) {
      throw StateError('名称不能为空');
    }
    if (name.startsWith('.')) {
      throw StateError('名称不能以点开头');
    }
    if (name.contains('/')) {
      throw StateError('名称不能包含 /');
    }
    final level = _normalizeDir(parentPrefix);
    final levelNames = await _ossClient.listEntryNames(level, session);
    final lowerName = name.toLowerCase();
    if (levelNames.any((entry) => entry.toLowerCase() == lowerName)) {
      throw StateError('该目录层级已存在同名条目');
    }
    for (final alias in _workspaceController.aliasTable.aliases) {
      if (alias.id == excludeAliasId) continue;
      if (_normalizeDir(alias.parentPrefix) == level &&
          alias.name.toLowerCase() == lowerName) {
        throw StateError('该目录层级已存在同名链接');
      }
    }
  }
}
