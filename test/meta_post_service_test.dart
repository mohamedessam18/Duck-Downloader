import 'dart:convert';

import 'package:duck_downloader/models/meta_post.dart';
import 'package:duck_downloader/services/meta_post_service.dart';
import 'package:duck_downloader/services/platform_sessions.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _image({int width = 1440, int height = 1800, String url = 'https://cdn/i.jpg'}) => {
  'media_type': 1,
  'image_versions2': {
    'candidates': [
      {'url': 'https://cdn/small.jpg', 'width': 320, 'height': 400},
      {'url': url, 'width': width, 'height': height},
    ],
  },
};

Map<String, dynamic> _video({String url = 'https://cdn/v.mp4'}) => {
  'media_type': 2,
  // Instagram sends a cover image on every video. Taking it because it is
  // there is how a Reel gets saved as a JPEG.
  'image_versions2': {
    'candidates': [
      {'url': 'https://cdn/cover.jpg', 'width': 1080, 'height': 1920},
    ],
  },
  'video_versions': [
    {'url': 'https://cdn/low.mp4', 'width': 480, 'height': 852},
    {'url': url, 'width': 1080, 'height': 1920},
  ],
};

dynamic _body(List<Map<String, dynamic>> children, {String? caption}) => {
  'items': [
    {
      if (caption != null) 'caption': {'text': caption},
      if (children.length == 1) ...children.first
      else ...{'media_type': 8, 'carousel_media': children},
    },
  ],
};

MetaPost _parse(dynamic body) =>
    MetaPostService.parseMediaInfo(body, 'ABC123')!;

void main() {
  group('links', () {
    test('every post shape yields its shortcode', () {
      for (final url in [
        'https://www.instagram.com/p/DHqXk_ZSAWk/',
        'https://instagram.com/reel/DHqXk_ZSAWk/',
        'https://www.instagram.com/reels/DHqXk_ZSAWk/',
        'https://www.instagram.com/tv/DHqXk_ZSAWk/?utm_source=ig',
      ]) {
        expect(MetaPostService.shortcodeOf(url), 'DHqXk_ZSAWk', reason: url);
      }
    });

    test('a profile or a non-post is not a post', () {
      expect(MetaPostService.shortcodeOf('https://instagram.com/someone'), isNull);
      expect(MetaPostService.shortcodeOf('https://example.com/p/ABC'), 'ABC');
      expect(MetaPostService.shortcodeOf('not a url'), isNull);
    });

    test('the shortcode is the media id in base 64', () {
      // Checked against Instagram's own numbering.
      expect(
        MetaPostService.mediaIdOf('DHqXk_ZSAWk').toString(),
        '3596790949449565604',
      );
      expect(MetaPostService.mediaIdOf('!!!'), isNull);
      expect(MetaPostService.mediaIdOf(''), isNull);
    });
  });

  group('Threads links', () {
    test('every post shape yields its shortcode', () {
      for (final url in [
        'https://www.threads.com/@zuck/post/C2QBoRaRmR1',
        'https://www.threads.net/@zuck/post/C2QBoRaRmR1',
        'https://threads.com/@some.one/post/C2QBoRaRmR1?xmt=abc',
        'https://www.threads.com/t/C2QBoRaRmR1',
      ]) {
        expect(MetaPostService.shortcodeOf(url), 'C2QBoRaRmR1', reason: url);
      }
    });

    test('a Threads link is recognised as one', () {
      expect(
        MetaPostService.platformOf('https://www.threads.com/@a/post/C2QBoRaRmR1'),
        SocialPlatform.threads,
      );
      expect(
        MetaPostService.platformOf('https://www.threads.net/@a/post/C2QBoRaRmR1'),
        SocialPlatform.threads,
      );
      expect(
        MetaPostService.platformOf('https://www.instagram.com/p/ABC/'),
        SocialPlatform.instagram,
      );
      // And nothing else is handled by this service at all.
      expect(MetaPostService.platformOf('https://x.com/a/status/1'), isNull);
      expect(MetaPostService.handles('https://youtu.be/abc'), isFalse);
    });

    test('the two platforms are addressed on their own domains', () {
      // Not a detail: the request has to carry the right origin's cookies,
      // and threads.net now answers a post URL with a 301 to threads.com.
      expect(
        MetaPostService.originFor(SocialPlatform.threads),
        'https://www.threads.com',
      );
      expect(
        MetaPostService.originFor(SocialPlatform.instagram),
        'https://www.instagram.com',
      );
      expect(
        MetaPostService.canonicalPostUrl(SocialPlatform.threads, 'ABC'),
        'https://www.threads.com/t/ABC',
      );
      expect(
        MetaPostService.canonicalPostUrl(SocialPlatform.instagram, 'ABC'),
        'https://www.instagram.com/p/ABC/',
      );
    });

    test('a Threads shortcode is the same base-64 as an Instagram one', () {
      // Threads runs on Instagram's media ids, which is why one parser reads
      // both and one fix fixes both.
      expect(
        MetaPostService.mediaIdOf('DHqXk_ZSAWk'),
        MetaPostService.mediaIdOf('DHqXk_ZSAWk'),
      );
      expect(MetaPostService.mediaIdOf('C2QBoRaRmR1'), isNotNull);
    });

    test('Threads posts parse into the same shapes', () {
      // Threads has no Reels, but every other shape is the same shape — which
      // is the point of not writing a second parser for it.
      final single = _parse(_body([_image(url: 'https://cdn/t1.jpg')]));
      expect(single.items.single.isVideo, isFalse);

      final video = _parse(_body([_video(url: 'https://cdn/t.mp4')]));
      expect(video.items.single.isVideo, isTrue);
      expect(video.items.single.url, 'https://cdn/t.mp4');

      final carousel = _parse(_body([
        _image(url: 'https://cdn/t1.jpg'),
        _image(url: 'https://cdn/t2.jpg'),
      ]));
      expect(carousel.items, hasLength(2));

      final mixed = _parse(_body([
        _image(url: 'https://cdn/t1.jpg'),
        _video(url: 'https://cdn/t2.mp4'),
        _image(url: 'https://cdn/t3.jpg'),
      ]));
      expect(mixed.isMixed, isTrue);
      expect(mixed.items.map((i) => i.isVideo), [false, true, false]);
    });
  });

  group('a saved session becomes a Cookie header', () {
    test('name=value pairs, semicolon separated', () {
      const jar = '# Netscape HTTP Cookie File\n'
          '.instagram.com\tTRUE\t/\tTRUE\t1799999999\tsessionid\tabc123\n'
          '.instagram.com\tTRUE\t/\tTRUE\t1799999999\tds_user_id\t42\n';
      final header = MetaPostService.cookieHeader(jar);
      expect(header, contains('sessionid=abc123'));
      expect(header, contains('ds_user_id=42'));
      expect(header, isNot(contains('Netscape')));
    });

    test('no session is an empty header, not a broken one', () {
      expect(MetaPostService.cookieHeader(null), '');
      expect(MetaPostService.cookieHeader(''), '');
      expect(MetaPostService.cookieHeader('# only a comment\n'), '');
    });
  });

  group('post shapes', () {
    test('a single image post is one image', () {
      final post = _parse(_body([_image()], caption: 'A caption'));
      expect(post.items, hasLength(1));
      expect(post.items.single.isVideo, isFalse);
      expect(post.items.single.url, 'https://cdn/i.jpg');
      expect(post.isMixed, isFalse);
      expect(post.title, 'A caption');
    });

    test('the original resolution wins, not the first listed', () {
      // Instagram usually lists largest first — until it does not, and the
      // user gets a 320px thumbnail of their own photo.
      final post = _parse(_body([
        {
          'media_type': 1,
          'image_versions2': {
            'candidates': [
              {'url': 'https://cdn/small.jpg', 'width': 320, 'height': 400},
              {'url': 'https://cdn/big.jpg', 'width': 1440, 'height': 1800},
            ],
          },
        }
      ]));
      expect(post.items.single.url, 'https://cdn/big.jpg');
    });

    test('a single video post is one video, not its cover', () {
      final post = _parse(_body([_video()]));
      expect(post.items, hasLength(1));
      expect(post.items.single.isVideo, isTrue);
      expect(post.items.single.url, 'https://cdn/v.mp4');
      // The cover survives as the thumbnail, which the options card shows and
      // the "cover image" download uses.
      expect(post.items.single.thumbnail, 'https://cdn/cover.jpg');
    });

    test('the largest video rendition is the one taken', () {
      final post = _parse(_body([_video()]));
      expect(post.items.single.height, 1920);
    });

    test('a carousel of images is every image', () {
      final post = _parse(_body([
        _image(url: 'https://cdn/1.jpg'),
        _image(url: 'https://cdn/2.jpg'),
        _image(url: 'https://cdn/3.jpg'),
      ]));
      expect(post.items, hasLength(3));
      expect(post.items.every((i) => !i.isVideo), isTrue);
      expect(post.isMixed, isFalse);
    });

    test('a carousel of videos is every video', () {
      final post = _parse(_body([
        _video(url: 'https://cdn/1.mp4'),
        _video(url: 'https://cdn/2.mp4'),
      ]));
      expect(post.items, hasLength(2));
      expect(post.items.every((i) => i.isVideo), isTrue);
      expect(post.isMixed, isFalse);
    });

    test('a mixed carousel keeps each item as what it is', () {
      // The case the whole per-item type flag exists for. Downloading this as
      // one type gives four copies of the wrong thing.
      final post = _parse(_body([
        _image(url: 'https://cdn/1.jpg'),
        _video(url: 'https://cdn/2.mp4'),
        _image(url: 'https://cdn/3.jpg'),
        _video(url: 'https://cdn/4.mp4'),
      ]));
      expect(post.items, hasLength(4));
      expect(post.items.map((i) => i.isVideo), [false, true, false, true]);
      expect(post.isMixed, isTrue);
      expect(post.items[1].url, 'https://cdn/2.mp4');
      expect(post.items[3].url, 'https://cdn/4.mp4');
    });

    test('order is the order Instagram gave', () {
      final post = _parse(_body([
        _image(url: 'https://cdn/1.jpg'),
        _image(url: 'https://cdn/2.jpg'),
        _video(url: 'https://cdn/3.mp4'),
      ]));
      expect(
        post.items.map((i) => i.url),
        ['https://cdn/1.jpg', 'https://cdn/2.jpg', 'https://cdn/3.mp4'],
      );
    });

    test('a node with both a cover and a video is a video', () {
      final post = _parse(_body([
        {
          // media_type missing entirely, which happens on some carousels.
          'image_versions2': {
            'candidates': [
              {'url': 'https://cdn/cover.jpg', 'width': 1080, 'height': 1920},
            ],
          },
          'video_versions': [
            {'url': 'https://cdn/real.mp4', 'width': 1080, 'height': 1920},
          ],
        }
      ]));
      expect(post.items.single.isVideo, isTrue);
      expect(post.items.single.url, 'https://cdn/real.mp4');
    });

    test('a caption becomes a one-line title', () {
      final post = _parse(_body([_image()], caption: 'First line\nSecond line'));
      expect(post.title, 'First line');
    });

    test('no caption still has a title', () {
      expect(_parse(_body([_image()])).title, 'Instagram Post');
    });
  });

  group('bodies that are not posts', () {
    test('nothing usable is null, not a crash', () {
      expect(MetaPostService.parseMediaInfo(null, 'x'), isNull);
      expect(MetaPostService.parseMediaInfo('a string', 'x'), isNull);
      expect(MetaPostService.parseMediaInfo({'items': []}, 'x'), isNull);
      expect(MetaPostService.parseMediaInfo({'items': 'nope'}, 'x'), isNull);
      expect(
        MetaPostService.parseMediaInfo(jsonDecode('{"items":[{}]}'), 'x'),
        isNull,
      );
    });

    test('a carousel of unusable children is null', () {
      expect(
        MetaPostService.parseMediaInfo(
          {'items': [{'media_type': 8, 'carousel_media': [{}, 'junk']}]},
          'x',
        ),
        isNull,
      );
    });
  });
}
