import 'package:flutter/material.dart';
import '../../state/downloads_controller.dart';
import '../duck_liquid_glass.dart';
import 'media_thumb.dart';
import 'media_colors.dart';

class AudioQueueSheet extends StatelessWidget {
  const AudioQueueSheet({super.key, required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return DuckLiquidGlassSurface(
      borderRadius: 28,
      variant: DuckLiquidGlassVariant.panel,
      isLight: isLight,
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final queue = controller.audioQueue;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    children: [
                      const Text(
                        'Queue',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${queue.length} tracks',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  final queue = controller.audioQueue;
                  final currentIndex = controller.audioQueueIndex;
                  return ReorderableListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    itemCount: queue.length,
                    onReorder: controller.reorderQueue,
                    itemBuilder: (context, index) {
                      final item = queue[index];
                      final isPlaying = index == currentIndex;
                      return Dismissible(
                        key: ValueKey('${item.id}_$index'),
                        direction: isPlaying 
                          ? DismissDirection.none 
                          : DismissDirection.endToStart,
                        onDismissed: (_) {
                          controller.removeFromQueue(index);
                        },
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20.0),
                          color: mediaDanger,
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: MediaThumb(
                            url: item.thumbnail,
                            filePath: item.filePath,
                            width: 48,
                            height: 48,
                            radius: 8,
                            icon: Icons.music_note,
                          ),
                          title: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isPlaying ? mediaGold : Colors.white,
                              fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text(
                            item.platform,
                            style: TextStyle(
                              color: isPlaying ? mediaGold.withOpacity(0.7) : Colors.white60,
                            ),
                          ),
                          trailing: ReorderableDragStartListener(
                            index: index,
                            child: const Icon(Icons.drag_handle, color: Colors.white38),
                          ),
                          onTap: () {
                            controller.playFromQueue(index);
                          },
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
