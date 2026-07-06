import 'package:flutter/material.dart';

import '../../models/download_models.dart';
import '../../state/downloads_controller.dart';
import 'duck_image_gallery.dart';
import 'duck_player_overlay.dart';

class MediaOverlayRouter extends StatelessWidget {
  const MediaOverlayRouter({
    super.key,
    required this.controller,
    this.galleryItems,
  });

  final DuckDownloadsController controller;
  final List<DownloadItem>? galleryItems;

  @override
  Widget build(BuildContext context) {
    final item = controller.playerItem;
    if (item == null) return const SizedBox.shrink();

    if (item.isImage) {
      final images = controller.playerGalleryItems ??
          galleryItems ??
          (item.isPrivate
              ? controller.privateDownloads.where((d) => d.isImage).toList()
              : controller.images);
      return DuckImageGallery(
        item: item,
        allImages: images,
        controller: controller,
      );
    }

    return DuckPlayerOverlay(item: item, controller: controller);
  }
}
