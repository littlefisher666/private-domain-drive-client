/// 目录统计结果：直属条目数与最新更新时间。
class DirectorySummary {
  const DirectorySummary({required this.itemCount, required this.updatedAt});

  final int itemCount;
  final DateTime? updatedAt;
}
