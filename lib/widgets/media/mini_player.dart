import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../state/downloads_controller.dart';
import 'audio_progress.dart';
import 'media_colors.dart';
import 'media_thumb.dart';
import 'liquid_interactive_button.dart';

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
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withOpacity(0.14),
                        Colors.white.withOpacity(0.03),
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.20),
                      width: 1,
                    ),
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
                            _buildMiniPlayerButton(
                              context: context,
                              icon: controller.hasPreviousTrack
                                  ? Icons.skip_previous
                                  : Icons.skip_previous_outlined,
                              color: controller.hasPreviousTrack
                                  ? Colors.white
                                  : Colors.white38,
                              size: 26,
                              onPressed: controller.hasPreviousTrack
                                  ? controller.playPrevious
                                  : null,
                            ),
                            _buildMiniPlayerButton(
                              context: context,
                              icon: isCompleted
                                  ? Icons.replay
                                  : playing
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              color: Colors.white,
                              size: 28,
                              onPressed: () {
                                if (isCompleted) {
                                  audio.seek(Duration.zero);
                                  audio.play();
                                } else {
                                  playing ? audio.pause() : audio.play();
                                }
                              },
                            ),
                            _buildMiniPlayerButton(
                              context: context,
                              icon: controller.hasNextTrack
                                  ? Icons.skip_next
                                  : Icons.skip_next_outlined,
                              color: controller.hasNextTrack
                                  ? Colors.white
                                  : Colors.white38,
                              size: 26,
                              onPressed:
                                  controller.hasNextTrack ? controller.playNext : null,
                            ),
                            _buildMiniPlayerButton(
                              context: context,
                              icon: Icons.close,
                              color: Colors.white70,
                              size: 22,
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
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMiniPlayerButton({
    required BuildContext context,
    required IconData icon,
    required Color color,
    required double size,
    required VoidCallback? onPressed,
  }) {
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;

    if (isAndroid) {
      return IconButton(
        icon: Icon(icon, color: color, size: size),
        onPressed: onPressed,
      );
    }

    final buttonContent = Container(
      width: size + 16.0,
      height: size + 16.0,
      alignment: Alignment.center,
      child: Icon(icon, color: color, size: size),
    );

    if (onPressed == null) {
      return Opacity(
        opacity: 0.38,
        child: buttonContent,
      );
    }

    return LiquidGlassInteractiveButton(
      onTap: onPressed,
      size: size + 16.0,
      child: buttonContent,
    );
  }
}
