import 'photo_entry.dart';

/// 时间线分组：按拍摄日期的「天」分组。
class TimelineGroup {
  const TimelineGroup({
    required this.key,
    required this.label,
    required this.start,
    required this.entries,
  });

  /// 分组稳定键（yyyy-MM-dd）。
  final String key;
  final String label;
  final DateTime start;
  final List<PhotoEntry> entries;
}

/// 将按拍摄时间（EXIF 拍摄日期，非上传日期）倒序排列的照片按天分组；
/// 无照片的日期不产生分组。
List<TimelineGroup> groupTimeline(
  Iterable<PhotoEntry> entries, {
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
    final key =
        '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
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
        label: _labelFor(key, today, yesterday),
        start: DateTime(
          int.parse(key.substring(0, 4)),
          int.parse(key.substring(5, 7)),
          int.parse(key.substring(8, 10)),
        ),
        entries: buckets[key]!,
      ),
  ];
}

String _labelFor(String key, DateTime today, DateTime yesterday) {
  final year = int.parse(key.substring(0, 4));
  final month = int.parse(key.substring(5, 7));
  final day = int.parse(key.substring(8, 10));
  final date = DateTime(year, month, day);
  if (date == today) return '今天';
  if (date == yesterday) return '昨天';
  const weekdays = <String>['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
  return '${date.month}月${date.day}日 ${weekdays[date.weekday - 1]}';
}
