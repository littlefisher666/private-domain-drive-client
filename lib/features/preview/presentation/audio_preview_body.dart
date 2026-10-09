import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../workspace/domain/file_item.dart';

/// 音频预览组件：预签名 URL 交给 media_kit 流式播放，提供播放/暂停、
/// 可拖动进度条与时长展示。组件销毁时 dispose 播放器即停止播放。
class AudioPreviewBody extends StatefulWidget {
  const AudioPreviewBody({
    super.key,
    required this.item,
    required this.urlLoader,
  });

  final FileItem item;

  /// 返回用于流式播放的预签名 URL。
  final Future<String> Function(FileItem item) urlLoader;

  @override
  State<AudioPreviewBody> createState() => _AudioPreviewBodyState();
}

class _AudioPreviewBodyState extends State<AudioPreviewBody> {
  Player? _player;
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  int _loadSeq = 0;
  bool _loading = true;
  bool _failed = false;
  bool _playing = false;
  bool _completed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant AudioPreviewBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path) {
      _start();
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    unawaited(_player?.dispose());
    _player = null;
    super.dispose();
  }

  Future<void> _start() async {
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _failed = false;
      _playing = false;
      _completed = false;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    try {
      final url = await widget.urlLoader(widget.item);
      if (!mounted || seq != _loadSeq) return;
      final player = Player();
      _listenPlayer(player, seq);
      await player.open(Media(url));
      if (!mounted || seq != _loadSeq) {
        unawaited(player.dispose());
        return;
      }
      setState(() {
        _loading = false;
        _player = player;
      });
    } catch (error) {
      if (!mounted || seq != _loadSeq) return;
      debugPrint('音频预览加载失败：${widget.item.path}（$error）');
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _listenPlayer(Player player, int seq) {
    _subscriptions.add(player.stream.playing.listen((playing) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _playing = playing;
        if (playing) _completed = false;
      });
    }));
    _subscriptions.add(player.stream.position.listen((position) {
      if (!mounted || seq != _loadSeq) return;
      setState(() => _position = position);
    }));
    _subscriptions.add(player.stream.duration.listen((duration) {
      if (!mounted || seq != _loadSeq) return;
      setState(() => _duration = duration);
    }));
    _subscriptions.add(player.stream.completed.listen((completed) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _completed = completed;
        if (completed) _playing = false;
      });
    }));
    _subscriptions.add(player.stream.error.listen((error) {
      if (!mounted || seq != _loadSeq || error.isEmpty) return;
      debugPrint('音频播放错误：${widget.item.path}（$error）');
      setState(() {
        _loading = false;
        _failed = true;
      });
    }));
  }

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null) return;
    if (_completed) {
      await player.seek(Duration.zero);
      await player.play();
      return;
    }
    if (_playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> _seekTo(Duration position) async {
    await _player?.seek(position);
    setState(() => _position = position);
  }

  void _retry() {
    final old = _player;
    _player = null;
    if (old != null) {
      for (final subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
      _subscriptions.clear();
      unawaited(old.dispose());
    }
    _start();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed || _player == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 72),
            const SizedBox(height: 12),
            Text('音频加载失败', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _retry, child: const Text('重试')),
          ],
        ),
      );
    }
    final total = _duration;
    final position = _position > total && total > Duration.zero
        ? total
        : _position;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.music_note_rounded,
              size: 96,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 8),
            Text(
              widget.item.name,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            Row(
              children: <Widget>[
                Text(
                  _formatDuration(position),
                  style: theme.textTheme.labelMedium,
                ),
                Expanded(
                  child: Slider(
                    value: total > Duration.zero
                        ? position.inMilliseconds
                            .clamp(0, total.inMilliseconds)
                            .toDouble()
                        : 0,
                    max: total > Duration.zero
                        ? total.inMilliseconds.toDouble()
                        : 1,
                    onChanged: total > Duration.zero
                        ? (value) =>
                            _seekTo(Duration(milliseconds: value.toInt()))
                        : null,
                  ),
                ),
                Text(
                  _formatDuration(total),
                  style: theme.textTheme.labelMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            IconButton.filled(
              onPressed: _togglePlay,
              iconSize: 40,
              icon: Icon(
                _playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = duration.inHours;
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}
