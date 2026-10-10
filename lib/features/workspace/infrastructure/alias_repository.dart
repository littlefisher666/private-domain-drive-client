import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../auth/domain/user_session.dart';
import 'oss_client.dart';
import '../domain/directory_alias.dart';

/// 别名表写入失败：并发冲突重试后仍不成功。
class AliasWriteConflictException implements Exception {
  const AliasWriteConflictException();
}

/// 虚拟目录别名仓库：`shared/.aliases/links.json` 的读取与
/// 读-改-写（写前复查 ETag 的乐观并发）。
class AliasRepository {
  AliasRepository({required OssClient ossClient}) : _ossClient = ossClient;

  final OssClient _ossClient;

  /// links.json 是纯配置文本，1MB 上限远超合理规模。
  static const _maxBytes = 1 * 1024 * 1024;
  static const _writeMaxAttempts = 3;

  String tableKey(UserSession session) =>
      '${session.rootPrefix}.aliases/links.json';

  /// 读取别名表。对象不存在或 JSON 损坏按空表降级并记录日志，
  /// 不阻塞目录浏览；网络等错误原样抛出。
  Future<DirectoryAliasTable> load(UserSession session) async {
    try {
      final loaded = await _loadWithEtag(session);
      return loaded?.$1 ?? const DirectoryAliasTable();
    } on FormatException catch (error) {
      _logDecodeFailure(error);
      return const DirectoryAliasTable();
    }
  }

  /// 读-改-写整个别名表：读取时记录 ETag，写入前复查；发现并发写入
  /// 则退避后重读重放本端变更。原生上传不支持条件写，采用读后复查
  /// 缩小竞态窗口（与相册清单同构）。超限抛出
  /// [AliasWriteConflictException]。
  Future<DirectoryAliasTable> update(
    UserSession session,
    DirectoryAliasTable Function(DirectoryAliasTable table) mutate,
  ) async {
    for (var attempt = 0; attempt < _writeMaxAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(
          Duration(
            milliseconds:
                200 * pow(2, attempt).round() + Random().nextInt(150),
          ),
        );
      }
      DirectoryAliasTable current;
      String currentEtag;
      try {
        final loaded = await _loadWithEtag(session);
        currentEtag = loaded?.$2 ?? '';
        current = loaded?.$1 ?? const DirectoryAliasTable();
      } on FormatException catch (error) {
        // 损坏的表内容不自动修复，仅在用户主动变更时覆盖。
        _logDecodeFailure(error);
        currentEtag = '';
        current = const DirectoryAliasTable();
      }
      final next = mutate(current);
      // 写入前复查 ETag：变化说明期间有并发写入，退避重试。
      try {
        final latest = await _loadWithEtag(session);
        if (latest != null && latest.$2 != currentEtag) {
          continue;
        }
      } on FormatException {
        // 复查读取损坏按无并发处理，避免永久卡死写入。
      } catch (_) {
        // 复查失败时按原计划写入；操作低频，极端冲突由下次写入兜底。
      }
      await _ossClient.uploadText(tableKey(session), next.encode(), session);
      return next;
    }
    throw const AliasWriteConflictException();
  }

  Future<(DirectoryAliasTable, String)?> _loadWithEtag(
    UserSession session,
  ) async {
    final key = tableKey(session);
    final objects = await _ossClient.listAllObjects(key, session);
    if (objects.isEmpty) return null;
    final etag = objects.firstWhere((object) => object.key == key).etag ?? '';
    final bytes = await _ossClient.download(key, session, maxBytes: _maxBytes);
    return (DirectoryAliasTable.decode(utf8.decode(bytes)), etag);
  }

  void _logDecodeFailure(Object error) {
    if (kDebugMode) {
      debugPrint('[alias] links.json 解析失败，按空表处理: $error');
    }
  }
}
