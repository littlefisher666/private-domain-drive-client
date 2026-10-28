/// 传输模块共享格式化：字节、速度、时长与绝对时间。
///
/// 时间戳统一按本地时区展示；缺失值一律使用占位符，避免伪造时间或
/// 零速度。
library;

const String transferUnknownPlaceholder = '—';

String formatTransferBytes(int bytes) {
  if (bytes < 0) return transferUnknownPlaceholder;
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String formatTransferSpeed(double? bytesPerSecond) {
  if (bytesPerSecond == null || bytesPerSecond <= 0) {
    return transferUnknownPlaceholder;
  }
  return '${formatTransferBytes(bytesPerSecond.round())}/s';
}

String formatTransferDuration(int? milliseconds) {
  if (milliseconds == null || milliseconds < 0) {
    return transferUnknownPlaceholder;
  }
  final seconds = milliseconds ~/ 1000;
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;
  if (minutes < 60) {
    return remainingSeconds == 0
        ? '$minutes 分'
        : '$minutes 分 $remainingSeconds 秒';
  }
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return remainingMinutes == 0
      ? '$hours 小时'
      : '$hours 小时 $remainingMinutes 分';
}

String formatTransferTimestamp(DateTime? time, {DateTime? now}) {
  if (time == null) return transferUnknownPlaceholder;
  final local = time.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(current.year, current.month, current.day);
  final hourMinute =
      '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
  final dayOffset = today.difference(day).inDays;
  if (dayOffset == 0) return '今天 $hourMinute';
  if (dayOffset == 1) return '昨天 $hourMinute';
  if (local.year == current.year) {
    return '${_twoDigits(local.month)}-${_twoDigits(local.day)} $hourMinute';
  }
  return '${local.year}-${_twoDigits(local.month)}-'
      '${_twoDigits(local.day)} $hourMinute';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
