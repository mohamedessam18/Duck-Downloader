import 'package:flutter_test/flutter_test.dart';
import 'package:duck_downloader/models/download_models.dart';
import 'package:duck_downloader/services/youtube_explode_service.dart';
import 'package:duck_downloader/services/cobalt_service.dart';

void main() {
  group('R3 Exhaustive YouTube URL Interception & Compliance Stress-Test', () {
    final exhaustiveYoutubeUrls = [
      // Standard Watch URLs
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://youtube.com/watch?v=dQw4w9WgXcQ',
      'http://www.youtube.com/watch?v=dQw4w9WgXcQ',
      'http://youtube.com/watch?v=dQw4w9WgXcQ',
      'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://music.youtube.com/watch?v=dQw4w9WgXcQ',
      'HTTPS://WWW.YOUTUBE.COM/WATCH?V=dQw4w9WgXcQ',
      'HtTpS://YoUtUbE.cOm/WaTcH?v=dQw4w9WgXcQ',

      // Shortened Domain URLs
      'https://youtu.be/dQw4w9WgXcQ',
      'http://youtu.be/dQw4w9WgXcQ',
      'https://www.youtu.be/dQw4w9WgXcQ',
      'HTTPS://YOUTU.BE/dQw4w9WgXcQ',
      'https://youtu.be/dQw4w9WgXcQ?t=30',

      // Shorts URLs
      'https://youtube.com/shorts/dQw4w9WgXcQ',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ',
      'https://m.youtube.com/shorts/dQw4w9WgXcQ',
      'HTTPS://WWW.YOUTUBE.COM/SHORTS/dQw4w9WgXcQ',

      // Playlist URLs
      'https://youtube.com/playlist?list=PL1234567890',
      'https://www.youtube.com/playlist?list=PL1234567890',
      'https://m.youtube.com/playlist?list=PL1234567890',
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1234567890',

      // Live, Clip, Embed, and No-Cookie URLs
      'https://www.youtube.com/live/dQw4w9WgXcQ',
      'https://youtube.com/live/dQw4w9WgXcQ',
      'https://www.youtube.com/clip/Ugkx123456789',
      'https://youtube.com/clip/Ugkx123456789',
      'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ',
      'https://youtube-nocookie.com/embed/dQw4w9WgXcQ',
      'https://www.youtube.com/embed/dQw4w9WgXcQ',
      'https://www.youtube.com/v/dQw4w9WgXcQ',
      'https://www.youtube.com/e/dQw4w9WgXcQ',

      // Dirty Query Strings & Tracking Params
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ&feature=shared',
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ&utm_source=twitter&utm_medium=social',
      'https://youtu.be/dQw4w9WgXcQ?si=abcdef12345',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ?feature=share',
      'https://m.youtube.com/watch?app=desktop&v=dQw4w9WgXcQ',
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ&ab_channel=TestChannel',
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ&fbclid=123456',
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ#t=1m30s',
      '  https://www.youtube.com/watch?v=dQw4w9WgXcQ  ',
    ];

    test('100% of exhaustive YouTube URL formats are identified by YouTubeExplodeService', () {
      for (final url in exhaustiveYoutubeUrls) {
        final cleanUrl = url.trim();
        final isYt = YouTubeExplodeService.isYouTubeUrl(cleanUrl) ||
            YouTubeExplodeService.isYouTubePlaylistUrl(cleanUrl);
        expect(isYt, isTrue, reason: 'Failed interception for URL: "$url"');
      }
    });

    test('100% of YouTube URLs return false for CobaltService.isSupported', () {
      for (final url in exhaustiveYoutubeUrls) {
        final cleanUrl = url.trim();
        final supportedByCobalt = CobaltService.isSupported(cleanUrl);
        expect(
          supportedByCobalt,
          isFalse,
          reason: 'CobaltService.isSupported must return false for YouTube URL: "$url"',
        );
      }
    });

    test('CobaltService.getDownloadUrl immediately returns null for YouTube URLs without HTTP dispatch', () async {
      for (final url in exhaustiveYoutubeUrls) {
        final cleanUrl = url.trim();
        final downloadUrl = await CobaltService.getDownloadUrl(
          url: cleanUrl,
          type: DownloadType.video,
        );
        expect(
          downloadUrl,
          isNull,
          reason: 'CobaltService.getDownloadUrl must return null for YouTube URL: "$url"',
        );
      }
    });

    test('YouTubeExplodeService methods throw policy compliance exceptions on YouTube URLs', () async {
      final service = YouTubeExplodeService();
      const testUrl = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

      expect(
        () => service.extractPlaylist(testUrl),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('YouTube downloads are not supported under Google Play policies.'),
        )),
      );

      expect(
        () => service.extractMetadata(testUrl),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('YouTube downloads are not supported under Google Play policies.'),
        )),
      );

      expect(
        () => service.downloadAudioNative(videoUrl: testUrl, title: 'test'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('YouTube downloads are not supported under Google Play policies.'),
        )),
      );

      expect(
        () => service.downloadVideoNative(videoUrl: testUrl, title: 'test'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('YouTube downloads are not supported under Google Play policies.'),
        )),
      );

      expect(
        () => service.downloadStream(
          streamUrl: testUrl,
          title: 'test',
          type: DownloadType.video,
          ext: 'mp4',
        ),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('YouTube downloads are not supported under Google Play policies.'),
        )),
      );
    });

    test('Supported non-YouTube social media URLs return true for CobaltService.isSupported', () {
      final supportedSocialUrls = [
        'https://www.instagram.com/reel/C123456/',
        'https://www.threads.net/@user/post/C123456',
        'https://www.facebook.com/watch/?v=123456',
        'https://x.com/user/status/123456',
        'https://www.tiktok.com/@user/video/123456',
        'https://www.reddit.com/r/test/comments/123456',
        'https://soundcloud.com/user/track',
      ];

      for (final url in supportedSocialUrls) {
        expect(
          CobaltService.isSupported(url),
          isTrue,
          reason: 'CobaltService.isSupported failed for non-YouTube platform: "$url"',
        );
      }
    });
  });
}
