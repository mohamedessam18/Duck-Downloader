import 'dart:io';

import 'package:flutter/material.dart';

import 'media_colors.dart';

class MediaThumb extends StatelessWidget {
  const MediaThumb({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.filePath,
    this.icon = Icons.image,
    this.radius = 8,
    this.preferNetworkThumbnail = false,
  });

  final String? url;
  final String? filePath;
  final double width;
  final double height;
  final IconData icon;
  final double radius;
  final bool preferNetworkThumbnail;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: width,
      height: height,
      color: const Color(0xFF292A2D),
      child: Icon(icon, color: mediaGold),
    );

    ImageProvider? provider;
    final isAudioFile = filePath != null && _isAudioPath(filePath!);

    if (!preferNetworkThumbnail && filePath != null && !isAudioFile) {
      final file = File(filePath!);
      if (file.existsSync()) {
        provider = FileImage(file);
      }
    }
    if (provider == null && url != null && url!.isNotEmpty) {
      if (url!.startsWith('http://') || url!.startsWith('https://')) {
        provider = NetworkImage(url!);
      } else if (!preferNetworkThumbnail) {
        final file = File(url!);
        if (file.existsSync()) {
          provider = FileImage(file);
        }
      }
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: provider == null
          ? fallback
          : Image(
              image: provider,
              width: width,
              height: height,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }

  static bool _isAudioPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    return {'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus'}.contains(ext);
  }
}
