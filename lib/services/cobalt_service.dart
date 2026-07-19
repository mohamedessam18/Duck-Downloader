import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/download_models.dart';

class CobaltService {
  static const List<String> _instances = [
    'https://nuko-c.meowing.de',
    'https://api-cobalt.eversiege.network',
    'https://api.qwkuns.me',
    'https://api.cobalt.liubquanti.click',
  ];

  /// Returns true if the URL is from a platform supported by Cobalt.
  static bool isSupported(String url) {
    final lower = url.toLowerCase();
    return lower.contains('youtube.com') ||
        lower.contains('youtu.be') ||
        lower.contains('instagram.com') ||
        lower.contains('threads.net') ||
        lower.contains('threads.com') ||
        lower.contains('facebook.com') ||
        lower.contains('fb.watch') ||
        lower.contains('x.com') ||
        lower.contains('twitter.com') ||
        lower.contains('tiktok.com') ||
        lower.contains('reddit.com') ||
        lower.contains('soundcloud.com');
  }

  /// Queries the Cobalt API to get a direct download link for a given media URL.
  static Future<String?> getDownloadUrl({
    required String url,
    required DownloadType type,
    String? qualityLabel,
  }) async {
    if (!isSupported(url)) return null;

    // Map quality label to Cobalt's quality strings:
    // 'max', '4320', '2160', '1440', '1080', '720', '480', '360', '240', '144'
    String cobaltQuality = '1080';
    if (qualityLabel != null) {
      final cleanQ = qualityLabel.toLowerCase();
      if (cleanQ.contains('4k') || cleanQ.contains('2160')) {
        cobaltQuality = '2160';
      } else if (cleanQ.contains('2k') || cleanQ.contains('1440')) {
        cobaltQuality = '1440';
      } else if (cleanQ.contains('1080')) {
        cobaltQuality = '1080';
      } else if (cleanQ.contains('720')) {
        cobaltQuality = '720';
      } else if (cleanQ.contains('480')) {
        cobaltQuality = '480';
      } else if (cleanQ.contains('360')) {
        cobaltQuality = '360';
      } else if (cleanQ.contains('240')) {
        cobaltQuality = '240';
      } else if (cleanQ.contains('144')) {
        cobaltQuality = '144';
      }
    }

    final body = {
      'url': url,
      'downloadMode': type == DownloadType.audio ? 'audio' : 'auto',
      'videoQuality': cobaltQuality,
      'audioFormat': 'mp3',
      'filenameStyle': 'basic',
    };

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
    ));

    for (final instance in _instances) {
      try {
        final response = await dio.post(
          instance,
          data: body,
        );
        if (response.statusCode == 200 && response.data != null) {
          final data = response.data;
          final status = data['status'];
          if (status == 'redirect' || status == 'tunnel') {
            final downloadUrl = data['url'] as String?;
            if (downloadUrl != null && downloadUrl.isNotEmpty) {
              return downloadUrl;
            }
          }
        }
      } catch (e) {
        debugPrint('Cobalt instance $instance failed: $e');
      }
    }
    return null;
  }
}
