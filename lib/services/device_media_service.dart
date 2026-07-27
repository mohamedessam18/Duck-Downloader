import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/download_models.dart';

class DeviceMediaFolder {
  DeviceMediaFolder({
    required this.name,
    required this.path,
    required this.itemCount,
    this.coverPath,
    required this.items,
  });

  final String name;
  final String path;
  final int itemCount;
  final String? coverPath;
  final List<DownloadItem> items;
}

class DeviceMediaService {
  static const Set<String> videoExtensions = {'mp4', 'mkv', 'webm', 'avi', 'mov', 'flv', '3gp', 'm4v'};
  static const Set<String> audioExtensions = {'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'opus', 'wma'};
  static const Set<String> imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic'};

  Future<List<Directory>> getCommonStorageDirectories() async {
    final dirs = <Directory>[];
    try {
      final docDir = await getApplicationDocumentsDirectory();
      dirs.add(docDir);
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) dirs.add(extDir);

      if (Platform.isAndroid) {
        final sdCard = Directory('/storage/emulated/0');
        if (sdCard.existsSync()) {
          dirs.add(sdCard);
          final commonPaths = [
            'DCIM',
            'Pictures',
            'Download',
            'Movies',
            'Music',
            'Podcasts',
            'Telegram',
            'WhatsApp/Media',
            'Android/media/com.whatsapp/WhatsApp/Media',
          ];
          for (final path in commonPaths) {
            final target = Directory(p.join(sdCard.path, path));
            if (target.existsSync()) {
              dirs.add(target);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error getting storage directories: $e');
    }
    return dirs;
  }

  Future<List<DeviceMediaFolder>> getMediaFolders({
    required Set<String> extensions,
    required DownloadType type,
    List<DownloadItem>? existingDownloads,
  }) async {
    final folderMap = <String, List<DownloadItem>>{};

    if (existingDownloads != null) {
      for (final item in existingDownloads) {
        if (item.type != type || item.filePath == null) continue;
        final file = File(item.filePath!);
        if (!file.existsSync()) continue;
        String folderPath = file.parent.path;
        if (folderPath == '/storage/emulated/0' || folderPath.isEmpty) {
          folderPath = 'Main Storage';
        }
        folderMap.putIfAbsent(folderPath, () => []).add(item);
      }
    }

    final searchDirs = await getCommonStorageDirectories();
    for (final dir in searchDirs) {
      if (!dir.existsSync()) continue;
      try {
        final entities = dir.listSync(recursive: true, followLinks: false);
        for (final entity in entities) {
          if (entity is File) {
            final ext = p.extension(entity.path).replaceAll('.', '').toLowerCase();
            if (extensions.contains(ext)) {
              String folderPath = entity.parent.path;
              if (folderPath == '/storage/emulated/0' || folderPath.isEmpty) {
                folderPath = 'Main Storage';
              }
              final filename = p.basename(entity.path);
              final existing = folderMap[folderPath]?.any((i) => i.filePath == entity.path) ?? false;
              if (!existing) {
                final item = DownloadItem(
                  id: entity.path,
                  url: entity.path,
                  title: filename,
                  filePath: entity.path,
                  type: type,
                  quality: 'Device Media',
                  createdAt: entity.statSync().modified,
                  status: DownloadStatus.completed,
                  progress: 100,
                  favorite: false,
                  platform: 'Device',
                );
                folderMap.putIfAbsent(folderPath, () => []).add(item);
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Folder scan error for ${dir.path}: $e');
      }
    }

    final result = <DeviceMediaFolder>[];
    folderMap.forEach((folderPath, items) {
      if (items.isNotEmpty) {
        String folderName = p.basename(folderPath);
        if (folderPath == 'Main Storage' || folderName.isEmpty || folderPath == '/storage/emulated/0') {
          folderName = 'Main Storage';
        }
        result.add(
          DeviceMediaFolder(
            name: folderName,
            path: folderPath,
            itemCount: items.length,
            coverPath: items.first.thumbnail ?? items.first.filePath,
            items: items,
          ),
        );
      }
    });

    result.sort((a, b) => b.items.length.compareTo(a.items.length));
    return result;
  }

  Future<List<DeviceMediaFolder>> getVideoFolders(List<DownloadItem> downloads) {
    return getMediaFolders(
      extensions: videoExtensions,
      type: DownloadType.video,
      existingDownloads: downloads,
    );
  }

  Future<List<DeviceMediaFolder>> getImageFolders(List<DownloadItem> downloads) {
    return getMediaFolders(
      extensions: imageExtensions,
      type: DownloadType.image,
      existingDownloads: downloads,
    );
  }

  Future<List<DeviceMediaFolder>> getAudioFolders(List<DownloadItem> downloads) {
    return getMediaFolders(
      extensions: audioExtensions,
      type: DownloadType.audio,
      existingDownloads: downloads,
    );
  }
}
