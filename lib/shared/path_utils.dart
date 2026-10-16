/// 网盘对象键的根前缀：所有用户可见路径均位于其下。
const String rootPrefix = 'shared/';

/// 规范化目录路径：空路径回退根前缀，非空补齐尾部 `/`。
String normalizeDirPath(String path) {
  if (path.isEmpty) {
    return rootPrefix;
  }
  return path.endsWith('/') ? path : '$path/';
}

/// 计算父目录路径；顶层条目的父级回落为根前缀。
String parentPathOf(String path) {
  final normalized = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final idx = normalized.lastIndexOf('/');
  if (idx <= 0) {
    return rootPrefix;
  }
  return normalized.substring(0, idx + 1);
}
