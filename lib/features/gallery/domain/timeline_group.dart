import 'photo_entry.dart';

/// 时间线分组：桌面端按月、移动端按天。
class TimelineGroup {
  const TimelineGroup({
    required this.key,
    required this.label,
    required this.start,
    required this.entries,
  });

  /// 分组稳定键（yyyy-MM 或 yyyy-MM-dd）。
  final String key;
  final String label;
  final DateTime start;
  final List<PhotoEntry> entries;
}

/// 将按拍摄时间倒序排列的照片按平台粒度分组。
///
/// [byDay] 为 true 时移动端按天分组，否则桌面端按月分组。
List<TimelineGroup> groupTimeline(
  Iterable<PhotoEntry> entries, {
  required bool byDay,
  DateTime Function()? now,
}) {
  final current = (now ?? DateTime.now)();
  final today = DateTime(current.year, current.month, current.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final buckets = <String, List<PhotoEntry>>{};
  final orderedKeys = <String>[];
  for (final entry in entries) {
    final local = entry.takenAt;
    final day = DateTime(local.year, local.month, local.day);
    final key = byDay
        ? '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}'
        : '${day.year}-${day.month.toString().padLeft(2, '0')}';
    if (!buckets.containsKey(key)) {
      buckets[key] = <PhotoEntry>[];
      orderedKeys.add(key);
    }
    buckets[key]!.add(entry);
  }
  return <TimelineGroup>[
    for (final key in orderedKeys)
      TimelineGroup(
        key: key,
        label: _labelFor(key, byDay, today, yesterday),
        start: DateTime(
          int.parse(key.substring(0, 4)),
          int.parse(key.substring(5, 7)),
          byDay ? int.parse(key.substring(8, 10)) : 1,
        ),
        entries: buckets[key]!,
      ),
  ];
}

String _labelFor(String key, bool byDay, DateTime today, DateTime yesterday) {
  final year = int.parse(key.substring(0, 4));
  final month = int.parse(key.substring(5, 7));
  if (byDay) {
    final day = int.parse(key.substring(8, 10));
    final date = DateTime(year, month, day);
    if (date == today) return '今天';
    if (date == yesterday) return '昨天';
    const weekdays = <String>['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    return '${date.month}月${date.day}日 ${weekdays[date.weekday - 1]}';
  }
  return '$year年$month月';
}
