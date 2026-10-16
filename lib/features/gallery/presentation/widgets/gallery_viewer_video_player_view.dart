import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../shared/file_size_formatter_lite.dart';
import '../../application/gallery_controller.dart';
import '../../domain/photo_entry.dart';
import 'gallery_viewer_mobile_video_controls.dart';

/// 视频条目内嵌播放视图：默认展示截帧缩略图封面与播放按钮（不自动
/// 播放），点击后生成 OSS 预签名 URL 流式播放；失败时展示兜底面板
/// （重新播放 + 下载原图）。播放器与条目绑定，切换条目或退出查看器
/// 时停止播放并释放资源，避免后台持续拉流。
class VideoPlayerView extends StatefulWidget {
  const VideoPlayerView({super.key, required this.gallery, required this.entry});

  final GalleryController gallery;
  final PhotoEntry entry;

  @override
  State<VideoPlayerView> createState() => _VideoPlayerViewState();
}

class _VideoPlayerViewState extends State<VideoPlayerView> {
  Uint8List? _frameBytes;
  bool _loading = false;
  String? _errorText;

  Player? _player;
  VideoController? _videoController;
  StreamSubscription<String>? _errorSubscription;
  Timer? _speedTimer;
  String? _speedText;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _loadThumb();
  }

  @override
  void didUpdateWidget(covariant VideoPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.key != widget.entry.key) {
      _teardownPlayer();
      setState(() {
        _frameBytes = null;
        _loading = false;
        _errorText = null;
      });
      _loadThumb();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _speedTimer?.cancel();
    _errorSubscription?.cancel();
    final player = _player;
    _player = null;
    player?.dispose();
    super.dispose();
  }

  Future<void> _loadThumb() async {
    final bytes = await widget.gallery.loadThumbObject(widget.entry.thumbKey);
    if (_disposed) return;
    setState(() {
      _frameBytes = bytes == null ? null : Uint8List.fromList(bytes);
    });
  }

  Future<void> _startPlayback() async {
    if (_loading || _player != null) return;
    setState(() {
      _loading = true;
      _errorText = null;
    });
    // 预签名 URL 仅在内存中短期使用，不落盘、不写日志。
    final url = await widget.gallery.presignVideoUrl(widget.entry);
    if (_disposed) return;
    if (url == null) {
      setState(() {
        _loading = false;
        _errorText = '生成播放地址失败，请重试';
      });
      return;
    }
    final player = Player();
    final subscription = player.stream.error.listen(_onPlayerError);
    try {
      await player.open(Media(url));
    } catch (error) {
      // 预签名 URL 携带签名参数，不得写入日志，先整体脱敏再输出。
      debugPrint('[gallery] 视频播放器打开失败: $error');
      unawaited(player.dispose());
      unawaited(subscription.cancel());
      if (_disposed) return;
      setState(() {
        _loading = false;
        _errorText = '视频播放失败，可重新尝试或下载原图播放';
      });
      return;
    }
    if (_disposed) {
      await subscription.cancel();
      await player.dispose();
      return;
    }
    if (mounted && _errorText == null) {
      setState(() {
        _player = player;
        _videoController = VideoController(player);
        _loading = false;
        _errorSubscription = subscription;
      });
      _startSpeedPolling(player);
    } else {
      await subscription.cancel();
      await player.dispose();
    }
  }

  /// 每秒读取 mpv 的 cache-speed（网络拉流字节速率），在视频右上角
  /// 展示实时下载速度，便于观察流式缓冲进度。
  void _startSpeedPolling(Player player) {
    _speedTimer?.cancel();
    final native = player.platform;
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final raw = await (native as dynamic).getProperty('cache-speed');
        final bytes = int.tryParse('$raw') ?? 0;
        if (_disposed || !mounted || bytes <= 0) return;
        setState(() {
          _speedText = '↓ ${FileSizeFormatterLite.format(bytes)}/s';
        });
      } catch (_) {
        // 播放器已释放或属性不可用：保持当前显示，下轮再试。
      }
    });
  }

  void _onPlayerError(String error) {
    if (_disposed || !mounted) return;
    // 播放出错（解码失败、网络错误、URL 过期等）时回退兜底面板。
    // mpv 的错误信息可能内嵌完整播放 URL（含签名参数），日志前先脱敏。
    final sanitized = error.replaceAll(RegExp(r'https?://\S+'), '<oss-url>');
    debugPrint('[gallery] 视频播放错误: $sanitized');
    _teardownPlayer();
    setState(() {
      _loading = false;
      _errorText = '视频播放失败，可重新尝试或下载原图播放';
    });
  }

  void _teardownPlayer() {
    _speedTimer?.cancel();
    _speedTimer = null;
    _speedText = null;
    _errorSubscription?.cancel();
    _errorSubscription = null;
    final player = _player;
    _player = null;
    _videoController = null;
    if (player != null) {
      // 先暂停释放网络流，dispose 收尾；错误回调中可能已在卸载阶段。
      unawaited(player.dispose());
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _videoController;
    final player = _player;
    if (controller != null && player != null) {
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Video(
            controller: controller,
            // 移动端用自定义控制层：默认控制层会吞掉查看器的四方向
            // 滑动手势（亮度/音量滑动），导致播放中无法切换条目。
            controls: widget.gallery.isDesktop
                ? AdaptiveVideoControls
                : (state) => MobileVideoControls(player: player),
          ),
          if (_speedText != null)
            Positioned(
              top: 12,
              right: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _speedText!,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12),
                ),
              ),
            ),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _buildCover(),
        if (_errorText != null) _buildErrorPanel(),
      ],
    );
  }

  Widget _buildCover() {
    final bytes = _frameBytes;
    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(24),
            child: bytes == null || bytes.isEmpty
                ? Container(
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(
                      child: Icon(Icons.videocam_outlined,
                          size: 64, color: Colors.white38),
                    ),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(Uint8List.fromList(bytes),
                        fit: BoxFit.contain),
                  ),
          ),
          if (_loading)
            const CircularProgressIndicator(color: Colors.white70)
          else
            IconButton.filled(
              onPressed: _startPlayback,
              iconSize: 36,
              style: IconButton.styleFrom(
                backgroundColor: Colors.black54,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.play_arrow_rounded),
            ),
        ],
      ),
    );
  }

  Widget _buildErrorPanel() {
    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, color: Colors.white70, size: 40),
            const SizedBox(height: 12),
            Text(
              _errorText!,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _startPlayback,
                  icon: const Icon(Icons.refresh, color: Colors.white),
                  label: const Text('重新播放',
                      style: TextStyle(color: Colors.white)),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: () =>
                      widget.gallery.downloadOriginal(widget.entry),
                  icon: const Icon(Icons.download_outlined,
                      color: Colors.white),
                  label: Text(
                    '下载原图${widget.entry.size > 0 ? ' · ${FileSizeFormatterLite.format(widget.entry.size)}' : ''}',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
