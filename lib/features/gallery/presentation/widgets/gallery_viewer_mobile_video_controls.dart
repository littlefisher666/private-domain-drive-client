import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'gallery_viewer_shared_utils.dart';

/// 移动端视频控制层：点按切换播放/暂停，底部提供进度条拖动与时长。
/// 不拦截四方向滑动，保留查看器的条目切换与详情面板手势。
class MobileVideoControls extends StatefulWidget {
  const MobileVideoControls({super.key, required this.player});

  final Player player;

  @override
  State<MobileVideoControls> createState() => _MobileVideoControlsState();
}

class _MobileVideoControlsState extends State<MobileVideoControls> {
  bool _seeking = false;
  double _seekValue = 0;

  Player get _player => widget.player;

  void _togglePlay() {
    final playing = _player.state.playing;
    if (playing) {
      _player.pause();
    } else {
      _player.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _togglePlay,
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              children: <Widget>[
                StreamBuilder<bool>(
                  stream: _player.stream.playing,
                  initialData: _player.state.playing,
                  builder: (context, snapshot) {
                    final playing = snapshot.data ?? false;
                    return IconButton(
                      onPressed: _togglePlay,
                      iconSize: 24,
                      visualDensity: VisualDensity.compact,
                      color: Colors.white,
                      icon: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    );
                  },
                ),
                Expanded(
                  child: StreamBuilder<Duration>(
                    stream: _player.stream.position,
                    initialData: _player.state.position,
                    builder: (context, positionSnap) {
                      return StreamBuilder<Duration>(
                        stream: _player.stream.duration,
                        initialData: _player.state.duration,
                        builder: (context, durationSnap) {
                          final position = positionSnap.data ?? Duration.zero;
                          final duration = durationSnap.data ?? Duration.zero;
                          final totalMs = duration.inMilliseconds;
                          final value = _seeking
                              ? _seekValue
                              : totalMs > 0
                                  ? (position.inMilliseconds / totalMs)
                                      .clamp(0.0, 1.0)
                                  : 0.0;
                          return SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6),
                              overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 12),
                              padding: EdgeInsets.zero,
                            ),
                            child: Slider(
                              value: value,
                              onChanged: totalMs <= 0
                                  ? null
                                  : (newValue) {
                                      setState(() {
                                        _seeking = true;
                                        _seekValue = newValue;
                                      });
                                    },
                              onChangeEnd: (newValue) {
                                _player.seek(Duration(
                                  milliseconds:
                                      (newValue * totalMs).round(),
                                ));
                                setState(() => _seeking = false);
                              },
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                StreamBuilder<Duration>(
                  stream: _player.stream.duration,
                  initialData: _player.state.duration,
                  builder: (context, snapshot) {
                    return Text(
                      formatClock(snapshot.data ?? Duration.zero),
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        StreamBuilder<bool>(
          stream: _player.stream.buffering,
          initialData: _player.state.buffering,
          builder: (context, snapshot) {
            if (snapshot.data != true) return const SizedBox.shrink();
            return const Positioned.fill(
              child: Center(
                child: CircularProgressIndicator(color: Colors.white70),
              ),
            );
          },
        ),
      ],
    );
  }
}
