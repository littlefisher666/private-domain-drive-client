import 'package:flutter/material.dart';

import '../../../../shared/file_size_formatter_lite.dart';
import '../../../../shared/state/app_scope.dart';
import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';
import 'gallery_viewer_shared_utils.dart';

/// 桌面端查看器右侧信息栏。
class InfoPanel extends StatelessWidget {
  const InfoPanel({super.key, required this.gallery, required this.entry});

  final GalleryController gallery;
  final PhotoEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppScope.of(context);
    final cached = gallery.isCached(entry.key);
    final lat = entry.latitude;
    final lon = entry.longitude;

    return Container(
      width: 260,
      color: const Color(0xFF1F2128),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFF30333D)),
              ),
            ),
            alignment: Alignment.centerLeft,
            child: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFE8EAEF),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _infoGroup(
                    theme,
                    '基础',
                    <(String, String)>[
                      ('拍摄时间', formatTakenAt(entry.takenAt)),
                      if (entry.width != null && entry.height != null)
                        ('分辨率', '${entry.width} × ${entry.height}'),
                      ('原始大小', FileSizeFormatterLite.format(entry.size)),
                      ('格式', entry.extension.toUpperCase()),
                    ],
                  ),
                  _infoGroup(
                    theme,
                    '来源',
                    <(String, String)>[
                      ('所在目录', app.workspaceController.displayPath(entry.directory)),
                      if (entry.device != null) ('上传设备', entry.device!),
                    ],
                    trailing: _cacheRow(cached),
                  ),
                  if (lat != null && lon != null)
                    _infoGroup(
                      theme,
                      '位置',
                      <(String, String)>[
                        (
                          '拍摄地点',
                          '${lat.abs().toStringAsFixed(4)}° ${lat >= 0 ? 'N' : 'S'}, '
                              '${lon.abs().toStringAsFixed(4)}° ${lon >= 0 ? 'E' : 'W'}'
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cacheRow(bool cached) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          const Text('本机缓存',
              style: TextStyle(
                  fontSize: 12.5,
                  height: 1.35,
                  color: Color(0xFF8D93A1))),
          Row(
            children: <Widget>[
              Icon(
                cached ? Icons.check_circle_outline : Icons.cloud_outlined,
                size: 14,
                color:
                    cached ? const Color(0xFF8BD48B) : const Color(0xFFF0B26B),
              ),
              const SizedBox(width: 5),
              Text(
                cached ? '已缓存' : '未缓存',
                style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFFE8EAEF)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoGroup(
    ThemeData theme,
    String title,
    List<(String, String)> rows, {
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.labelSmall?.copyWith(
              color: const Color(0xFF7C828E),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 6),
          for (final (key, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    key,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.35,
                      color: Color(0xFF8D93A1),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      value,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.35,
                        color: Color(0xFFE8EAEF),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }
}
