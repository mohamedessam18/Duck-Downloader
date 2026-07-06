import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'media_slider.dart';

class AudioProgress extends StatelessWidget {
  const AudioProgress({
    super.key,
    required this.player,
    this.onSeek,
  });

  final AudioPlayer player;
  final ValueChanged<Duration>? onSeek;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration?>(
          stream: player.durationStream,
          builder: (context, durationSnapshot) {
            final position = positionSnapshot.data ?? player.position;
            final duration = durationSnapshot.data ?? player.duration ?? Duration.zero;
            return MediaSlider(
              position: position,
              duration: duration,
              onChanged: (pos) {
                if (onSeek != null) {
                  onSeek!(pos);
                } else {
                  player.seek(pos);
                }
              },
            );
          },
        );
      },
    );
  }
}

class AudioMiniProgress extends StatelessWidget {
  const AudioMiniProgress({super.key, required this.player});

  final AudioPlayer player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration?>(
          stream: player.durationStream,
          builder: (context, durationSnapshot) {
            final position = positionSnapshot.data ?? player.position;
            final duration = durationSnapshot.data ?? player.duration ?? Duration.zero;
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
