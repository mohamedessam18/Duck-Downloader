import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../state/downloads_controller.dart';
import '../duck_liquid_glass.dart';
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
            child: DuckLiquidGlassSurface(
              borderRadius: 16,
              variant: DuckLiquidGlassVariant.capsule,
              blurSigma: 20,
              fallbackGradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.14),
                  Colors.white.withValues(alpha: 0.03),
                ],
              ),
              fallbackBorderColor: Colors.white.withValues(alpha: 0.20),
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
                                // Asked, not assumed. This bar was written for
                                // music and described whatever it was handed
                                // as an audio file — so a paused video sat in
                                // it labelled "Audio file", which is what it
                                // looked like to the user: the app losing
                                // track of what their file was.
                                item.artist ??
                                    (item.isVideo ? 'Video' : 'Audio file'),
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
      useOwnLayer: false,
      child: buttonContent,
    );
  }
}
