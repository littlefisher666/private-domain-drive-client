/// EXIF 缺失时从文件名与目录名推断拍摄时间的兜底策略。
///
/// 微信等应用传图会剥离 EXIF，但命名常携带时间线索，按可信度依次：
/// 文件名毫秒时间戳（`wx_camera_1727347355953` / `mmexport1745395006753`）、
/// 文件名日期时间（`IMG_20240916_153000`、`Screenshot_2024-09-16-15-30-00`）、
/// 文件名日期（`微信图片_20240916.jpg`）、目录名日期前缀
/// （`20240916-电视安装/`，取当天 12:00）。
/// 仅采信 2000 年至当前时间之后的合理日期，避免误伤普通数字串。
DateTime? inferTakenAtFromName({
  required String fileName,
  required String directory,
}) {
  return _fromFileName(fileName) ?? _fromDirectory(directory);
}

final _epochMsPattern = RegExp(r'(?<!\d)(1[4-8]\d{11})(?!\d)');

/// 14 位连写日期时间：VID20251114212141（Android 录像常见命名）。
final _compactDateTimePattern = RegExp(r'(?<!\d)(\d{14})(?!\d)');

/// 紧凑日期+时间：IMG_20240916_153000 / Screenshot_2024-09-16-15-30-00。
final _nameDateTimePattern = RegExp(
  r'(\d{4})[-./]?(\d{2})[-./]?(\d{2})[_\-T ](\d{2})[-.:]?(\d{2})[-.:]?(\d{2})',
);

/// 独立的 8 位日期串：微信图片_20240916.jpg。
final _nameDatePattern = RegExp(r'(?:^|[_\-.])(\d{8})(?:[_\-.]|$)');

/// 目录段开头的日期前缀：20240916-电视安装 / 20250418。
final _dirDatePattern =
    RegExp(r'^(\d{4})(\d{2})(\d{2})(?=[\-_\s(（.]|$)');

DateTime? _fromFileName(String name) {
  for (final match in _epochMsPattern.allMatches(name)) {
    final candidate = DateTime.fromMillisecondsSinceEpoch(
      int.parse(match.group(1)!),
    );
    if (_plausible(candidate)) return candidate;
  }
  final compact = _compactDateTimePattern.firstMatch(name);
  if (compact != null) {
    final digits = compact.group(1)!;
    final candidate = _tryDateTime(
      int.parse(digits.substring(0, 4)),
      int.parse(digits.substring(4, 6)),
      int.parse(digits.substring(6, 8)),
      int.parse(digits.substring(8, 10)),
      int.parse(digits.substring(10, 12)),
      int.parse(digits.substring(12, 14)),
    );
    if (candidate != null) return candidate;
  }
  final dateTime = _nameDateTimePattern.firstMatch(name);
  if (dateTime != null) {
    final candidate = _tryDateTime(
      int.parse(dateTime.group(1)!),
      int.parse(dateTime.group(2)!),
      int.parse(dateTime.group(3)!),
      int.parse(dateTime.group(4)!),
      int.parse(dateTime.group(5)!),
      int.parse(dateTime.group(6)!),
    );
    if (candidate != null) return candidate;
  }
  final date = _nameDatePattern.firstMatch(name);
  if (date != null) {
    final candidate = _tryDate(
      int.parse(date.group(1)!.substring(0, 4)),
      int.parse(date.group(1)!.substring(4, 6)),
      int.parse(date.group(1)!.substring(6, 8)),
    );
    if (candidate != null) return _noon(candidate);
  }
  return null;
}

DateTime? _fromDirectory(String directory) {
  final segments = directory.split('/')
    ..removeWhere((segment) => segment.isEmpty);
  for (final segment in segments.reversed) {
    final match = _dirDatePattern.firstMatch(segment);
    if (match == null) continue;
    final candidate = _tryDate(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
    if (candidate != null) return _noon(candidate);
  }
  return null;
}

bool _plausible(DateTime value) =>
    !value.isBefore(DateTime(2000)) &&
    value.isBefore(DateTime.now().add(const Duration(days: 2)));

DateTime? _tryDateTime(
  int year,
  int month,
  int day,
  int hour,
  int minute,
  int second,
) {
  final date = _tryDate(year, month, day);
  if (date == null || hour > 23 || minute > 59 || second > 59) return null;
  return date.add(Duration(hours: hour, minutes: minute, seconds: second));
}

DateTime? _tryDate(int year, int month, int day) {
  if (year < 2000 || year > DateTime.now().year + 1) return null;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final date = DateTime(year, month, day);
  if (date.month != month || date.day != day) return null;
  return date;
}

DateTime _noon(DateTime date) => date.add(const Duration(hours: 12));
