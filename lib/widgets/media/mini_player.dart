import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../state/downloads_controller.dart';
import 'audio_progress.dart';
import 'media_colors.dart';
import 'media_thumb.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final item = controller.playingItem;
        if (item == null) return const SizedBox.shrink();

        final audio = controller.audioPlayer;
        final playing = audio.playing;
        final isCompleted =
            audio.processingState == ProcessingState.completed;

        return GestureDetector(
          onTap: () => controller.openPlayer(item),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E20),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: MediaThumb(
                          url: item.thumbnail,
                          preferNetworkThumbnail: true,
                          width: 48,
                          height: 48,
                          icon: Icons.music_note,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item.artist ?? 'Audio file',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  TextStyle(color: mediaWarmGold, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          controller.hasPreviousTrack
                              ? Icons.skip_previous
                              : Icons.skip_previous_outlined,
                          color: controller.hasPreviousTrack
                              ? Colors.white
                              : Colors.white38,
                          size: 26,
                        ),
                        onPressed: controller.hasPreviousTrack
                            ? controller.playPrevious
                            : null,
                      ),
                      IconButton(
                        icon: Icon(
                          isCompleted
                              ? Icons.replay
                              : playing
                              ? Icons.pause
                              : Icons.play_arrow,
                          color: Colors.white,
                          size: 28,
                        ),
                        onPressed: () {
                          if (isCompleted) {
                            audio.seek(Duration.zero);
                            audio.play();
                          } else {
                            playing ? audio.pause() : audio.play();
                          }
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          controller.hasNextTrack
                              ? Icons.skip_next
                              : Icons.skip_next_outlined,
                          color: controller.hasNextTrack
                              ? Colors.white
                              : Colors.white38,
                          size: 26,
                        ),
                        onPressed:
                            controller.hasNextTrack ? controller.playNext : null,
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.close,
                          color: Colors.white70,
                          size: 22,
                        ),
                        onPressed: controller.stopAudio,
                      ),
                    ],
                  ),
                ),
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(16),
                  ),
                  child: AudioMiniProgress(player: audio),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
