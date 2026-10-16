import '../../../transfer/domain/transfer_task.dart';
import '../../domain/photo_entry.dart';

/// 查找与对象 key 相关的最近下载任务（判断下载原图状态用）。
TransferTask? downloadTaskFor(List<TransferTask> tasks, PhotoEntry entry) {
  TransferTask? latest;
  for (final task in tasks) {
    if (task.type != TransferTaskType.download) continue;
    if (task.sourcePath != entry.key) continue;
    latest = task;
  }
  return latest;
}

/// 拍摄时间展示文本（移动端顶栏 / 详情面板 / 桌面信息栏共用）。
String formatTakenAt(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// 视频进度时长文本（移动端视频控制层共用）。
String formatClock(Duration duration) {
  final total = duration.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}
