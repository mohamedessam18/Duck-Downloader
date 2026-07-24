import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/download_models.dart';

class CobaltService {
  /// Cobalt public instances — ordered by reliability.
  /// TikTok downloads work best through Cobalt since TikTok
  /// uses signed CDN URLs that expire quickly.
  static const List<String> _instances = [
    'https://nuko-c.meowing.de',
    'https://api-cobalt.eversiege.network',
    'https://api.qwkuns.me',
    'https://api.cobalt.liubquanti.click',
    'https://cobalt.api.ggtyler.dev',
    'https://cobalt-api.hyper.lol',
    'https://co.wuk.sh',
  ];

  /// Returns true if the URL is from a platform supported by Cobalt.
  static bool isSupported(String url) {
    final lower = url.toLowerCase();
    return lower.contains('instagram.com') ||
        lower.contains('threads.net') ||
        lower.contains('threads.com') ||
        lower.contains('facebook.com') ||
        lower.contains('fb.watch') ||
        lower.contains('x.com') ||
        lower.contains('twitter.com') ||
        lower.contains('tiktok.com') ||
        lower.contains('vm.tiktok.com') ||
        lower.contains('reddit.com') ||
        lower.contains('soundcloud.com') ||
        lower.contains('youtube.com') ||
        lower.contains('youtu.be');
  }

  /// Returns true specifically for TikTok URLs.
  static bool isTikTok(String url) {
    final lower = url.toLowerCase();
    return lower.contains('tiktok.com') || lower.contains('vm.tiktok.com');
  }

  /// Queries the Cobalt API to get a direct download link for a given media URL.
  /// Tries all instances in order, returns null if all fail.
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
      'youtubeVideoCodec': 'h264',
      'audioFormat': 'mp3',
      'filenameStyle': 'basic',
      // TikTok-specific: disable watermark
      if (isTikTok(url)) 'tiktokFullAudio': false,
      if (isTikTok(url)) 'disableMetadata': false,
    };

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
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
              debugPrint('Cobalt [$instance] success for $url');
              return downloadUrl;
            }
          }
          // Some instances return 'picker' for multi-media (e.g. TikTok photo slides)
          if (status == 'picker') {
            final picker = data['picker'] as List?;
            if (picker != null && picker.isNotEmpty) {
              final first = picker.first as Map?;
              final pickerUrl = first?['url'] as String?;
              if (pickerUrl != null && pickerUrl.isNotEmpty) {
                debugPrint('Cobalt [$instance] picker url for $url');
                return pickerUrl;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Cobalt instance $instance failed: $e');
      }
    }
    return null;
  }

  /// Fetches all media URLs from a TikTok photo slide or multi-video post.
  /// Returns a list of URLs (empty if not a picker / not supported).
  static Future<List<String>> getPickerUrls({
    required String url,
  }) async {
    if (!isTikTok(url)) return [];

    final body = {
      'url': url,
      'downloadMode': 'auto',
      'filenameStyle': 'basic',
    };

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
    ));

    for (final instance in _instances) {
      try {
        final response = await dio.post(instance, data: body);
        if (response.statusCode == 200 && response.data != null) {
          final data = response.data;
          if (data['status'] == 'picker') {
            final picker = data['picker'] as List?;
            if (picker != null && picker.isNotEmpty) {
              return picker
                  .map((e) => (e as Map)['url'] as String?)
                  .whereType<String>()
                  .toList();
            }
          }
        }
      } catch (e) {
        debugPrint('Cobalt picker $instance failed: $e');
      }
    }
    return [];
  }
}
