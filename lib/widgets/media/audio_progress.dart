import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'media_slider.dart';

class AudioProgress extends StatefulWidget {
  const AudioProgress({
    super.key,
    required this.player,
    this.onSeek,
  });

  final AudioPlayer player;
  final ValueChanged<Duration>? onSeek;

  @override
  State<AudioProgress> createState() => _AudioProgressState();
}

class _AudioProgressState extends State<AudioProgress> {
  Duration _cachedDuration = Duration.zero;
  Duration? _draggedPosition;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration?>(
          stream: widget.player.durationStream,
          builder: (context, durationSnapshot) {
            var position = positionSnapshot.data ?? widget.player.position;
            if (_draggedPosition != null) {
              position = _draggedPosition!;
            }

            var duration = durationSnapshot.data ?? widget.player.duration ?? Duration.zero;
            if (_cachedDuration == Duration.zero && duration > Duration.zero) {
              _cachedDuration = duration;
            } else if (duration > Duration.zero && duration.inMilliseconds < _cachedDuration.inMilliseconds * 0.5) {
              duration = _cachedDuration;
            } else if (duration > Duration.zero) {
              _cachedDuration = duration;
            }
            if (duration == Duration.zero && _cachedDuration > Duration.zero) {
              duration = _cachedDuration;
            }

            return MediaSlider(
              position: position,
              duration: duration,
              onChanged: (pos) {
                if (mounted) setState(() => _draggedPosition = pos);
              },
              onChangeEnd: (pos) {
                if (mounted) setState(() => _draggedPosition = null);
                if (widget.onSeek != null) {
                  widget.onSeek!(pos);
                } else {
                  widget.player.seek(pos);
                }
              },
            );
          },
        );
      },
    );
  }
}

class AudioMiniProgress extends StatefulWidget {
  const AudioMiniProgress({super.key, required this.player});

  final AudioPlayer player;

  @override
  State<AudioMiniProgress> createState() => _AudioMiniProgressState();
}

class _AudioMiniProgressState extends State<AudioMiniProgress> {
  Duration _cachedDuration = Duration.zero;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration?>(
          stream: widget.player.durationStream,
          builder: (context, durationSnapshot) {
            final position = positionSnapshot.data ?? widget.player.position;
            var duration = durationSnapshot.data ?? widget.player.duration ?? Duration.zero;

            if (_cachedDuration == Duration.zero && duration > Duration.zero) {
              _cachedDuration = duration;
            } else if (duration > Duration.zero && duration.inMilliseconds < _cachedDuration.inMilliseconds * 0.5) {
              duration = _cachedDuration;
            } else if (duration > Duration.zero) {
              _cachedDuration = duration;
            }
            if (duration == Duration.zero && _cachedDuration > Duration.zero) {
              duration = _cachedDuration;
            }

            final progress = duration.inMilliseconds <= 0
                ? 0.0
                : position.inMilliseconds / duration.inMilliseconds;
            return LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: Colors.white12,
              color: const Color(0xFFFFC52F),
            );
          },
        );
      },
    );
  }
}
