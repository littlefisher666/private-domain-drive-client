import 'package:flutter/material.dart';

import '../../../../shared/file_size_formatter_lite.dart';
import '../../../../shared/state/app_scope.dart';
import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';
import 'gallery_viewer_shared_utils.dart';

/// 移动端照片详情面板（上滑呼出、下滑收起）。
class MobileDetailSheet extends StatelessWidget {
  const MobileDetailSheet({
    super.key,
    required this.gallery,
    required this.entry,
    required this.onClose,
  });

  final GalleryController gallery;
  final PhotoEntry entry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final cached = gallery.isCached(entry.key);
    final lat = entry.latitude;
    final lon = entry.longitude;

    return Container(
      constraints: const BoxConstraints(maxHeight: 300),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      decoration: const BoxDecoration(
        color: Color(0xFF1F2128),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF4A4E5A),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _group('基础', <(String, String)>[
                    ('拍摄时间', formatTakenAt(entry.takenAt)),
                    if (entry.width != null && entry.height != null)
                      ('分辨率', '${entry.width} × ${entry.height}'),
                    ('原始大小', FileSizeFormatterLite.format(entry.size)),
                    ('格式', entry.extension.toUpperCase()),
                  ]),
                  _group('来源', <(String, String)>[
                    ('所在目录', app.workspaceController.displayPath(entry.directory)),
                    if (entry.device != null) ('上传设备', entry.device!),
                    ('本机缓存', cached ? '已缓存' : '未缓存'),
                  ]),
                  if (lat != null && lon != null)
                    _group('位置', <(String, String)>[
                      (
                        '拍摄地点',
                        '${lat.abs().toStringAsFixed(4)}° ${lat >= 0 ? 'N' : 'S'}, '
                            '${lon.abs().toStringAsFixed(4)}° ${lon >= 0 ? 'E' : 'W'}'
                      ),
                    ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onClose,
            child: const Text('收起',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _group(String title, List<(String, String)> rows) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF7C828E),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 4),
          for (final (key, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    key,
                    style: const TextStyle(
                        fontSize: 12.5, color: Color(0xFF8D93A1)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      value,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFFE8EAEF),
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
