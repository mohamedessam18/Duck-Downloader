import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:duck_downloader/services/youtube_explode_service.dart';
import 'package:duck_downloader/services/cobalt_service.dart';

void main() {
  group('R3 YouTube URL Interception Challenge', () {
    final standardWatchUrls = [
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://youtube.com/watch?v=dQw4w9WgXcQ',
      'http://www.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://music.youtube.com/watch?v=dQw4w9WgXcQ',
      'HTTPS://WWW.YOUTUBE.COM/WATCH?V=dQw4w9WgXcQ',
    ];

    final shortenedUrls = [
      'https://youtu.be/dQw4w9WgXcQ',
      'http://youtu.be/dQw4w9WgXcQ',
      'https://www.youtu.be/dQw4w9WgXcQ',
    ];

    final shortsUrls = [
      'https://youtube.com/shorts/dQw4w9WgXcQ',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ',
      'https://m.youtube.com/shorts/dQw4w9WgXcQ',
    ];

    final playlistUrls = [
      'https://youtube.com/playlist?list=PL1234567890',
      'https://www.youtube.com/playlist?list=PL1234567890',
    ];

    final dirtyUrls = [
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ&feature=shared',
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ&utm_source=twitter&utm_medium=social',
      'https://youtu.be/dQw4w9WgXcQ?si=abcdef12345',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ?feature=share',
      'https://m.youtube.com/watch?app=desktop&v=dQw4w9WgXcQ',
    ];

    final edgeCaseUninterceptedUrls = [
      'https://www.youtube.com/live/dQw4w9WgXcQ',
      'https://www.youtube.com/clip/Ugkx123456789',
      'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ',
    ];

    test('Standard watch URLs are intercepted', () {
      for (final url in standardWatchUrls) {
        final isYt = YouTubeExplodeService.isYouTubeUrl(url) ||
            YouTubeExplodeService.isYouTubePlaylistUrl(url);
        expect(isYt, isTrue, reason: 'Failed for $url');
      }
    });

    test('Shortened domain URLs are intercepted', () {
      for (final url in shortenedUrls) {
        final isYt = YouTubeExplodeService.isYouTubeUrl(url) ||
            YouTubeExplodeService.isYouTubePlaylistUrl(url);
        expect(isYt, isTrue, reason: 'Failed for $url');
      }
    });

    test('Shorts URLs are intercepted', () {
      for (final url in shortsUrls) {
        final isYt = YouTubeExplodeService.isYouTubeUrl(url) ||
            YouTubeExplodeService.isYouTubePlaylistUrl(url);
        expect(isYt, isTrue, reason: 'Failed for $url');
      }
    });

    test('Playlist URLs are intercepted', () {
      for (final url in playlistUrls) {
        final isYt = YouTubeExplodeService.isYouTubeUrl(url) ||
            YouTubeExplodeService.isYouTubePlaylistUrl(url);
        expect(isYt, isTrue, reason: 'Failed for $url');
      }
    });

    test('Dirty query string URLs are intercepted', () {
      for (final url in dirtyUrls) {
        final isYt = YouTubeExplodeService.isYouTubeUrl(url) ||
            YouTubeExplodeService.isYouTubePlaylistUrl(url);
        expect(isYt, isTrue, reason: 'Failed for $url');
      }
    });

    test('Edge case URLs (Live, clip, nocookie) are intercepted and rejected by CobaltService', () {
      for (final url in edgeCaseUninterceptedUrls) {
        final isYt = YouTubeExplodeService.isYouTubeUrl(url) ||
            YouTubeExplodeService.isYouTubePlaylistUrl(url);
        expect(isYt, isTrue, reason: 'Edge case URL $url should be intercepted by YouTubeExplodeService');
        final supportedByCobalt = CobaltService.isSupported(url);
        expect(supportedByCobalt, isFalse,
            reason: 'YouTube URL $url must NOT be processed by CobaltService!');
      }
    });
  });

  group('R3 AndroidManifest.xml Permission Audit', () {
    test('Verify android/app/src/main/AndroidManifest.xml permissions', () {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(manifestFile.existsSync(), isTrue);
      final content = manifestFile.readAsStringSync();

      expect(content.contains('android.permission.READ_MEDIA_VIDEO" tools:node="remove"'), isTrue);
      expect(content.contains('android.permission.READ_MEDIA_AUDIO" tools:node="remove"'), isTrue);
      expect(content.contains('android.permission.READ_MEDIA_IMAGES" tools:node="remove"'), isTrue);
      expect(content.contains('android.permission.WRITE_EXTERNAL_STORAGE'), isFalse);

      final hasReadStorageWithMaxSdk = content.contains('READ_EXTERNAL_STORAGE') &&
          content.contains('android:maxSdkVersion="32"');
      expect(hasReadStorageWithMaxSdk, isTrue);
    });
  });
}
