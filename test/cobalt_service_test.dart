import 'package:duck_downloader/services/cobalt_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CobaltService tests', () {
    test('isSupported returns true for YouTube URLs', () {
      expect(CobaltService.isSupported('https://www.youtube.com/watch?v=123'), isTrue);
      expect(CobaltService.isSupported('https://youtu.be/123'), isTrue);
    });

    test('isSupported returns true for Reddit video URLs', () {
      expect(CobaltService.isSupported('https://www.reddit.com/r/test/comments/abc/'), isTrue);
      expect(CobaltService.isSupported('https://redd.it/abc123'), isTrue);
      expect(CobaltService.isSupported('https://v.redd.it/abc123'), isTrue);
    });

    test('isSupported returns true for supported non-YouTube social media platforms', () {
      expect(CobaltService.isSupported('https://www.instagram.com/reel/123'), isTrue);
      expect(CobaltService.isSupported('https://facebook.com/watch?v=123'), isTrue);
      expect(CobaltService.isSupported('https://x.com/user/status/123'), isTrue);
      expect(CobaltService.isSupported('https://tiktok.com/@user/video/123'), isTrue);
    });

    test('isSupported returns false for unsupported platforms', () {
      expect(CobaltService.isSupported('https://example.com'), isFalse);
      expect(CobaltService.isSupported('https://google.com'), isFalse);
      expect(CobaltService.isSupported('https://github.com'), isFalse);
    });
  });
}
