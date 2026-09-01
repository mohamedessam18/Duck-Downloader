import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

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
  group('the request Threads actually gets', () {
    /// Records every request and answers each with a queued status.
    late List<RequestOptions> sent;

    MetaPostService serviceAnswering(List<int> statuses, {String? body}) {
      sent = [];
      final dio = Dio(
        BaseOptions(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      var call = 0;
      dio.httpClientAdapter = _ScriptedAdapter((options) {
        sent.add(options);
        final status = statuses[call.clamp(0, statuses.length - 1)];
        call++;
        return ResponseBody.fromString(
          status == 200 ? (body ?? '{"items":[]}') : '',
          status,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      return MetaPostService(dio: dio, pageReader: (_) async => null);
    }

    test('a Threads post is asked for on threads.com, with its own id', () async {
      final service = serviceAnswering([200], body: _oneImageBody);
      await service.fetchPost('https://www.threads.com/@a/post/C2QBoRaRmR1');

      expect(sent, hasLength(1));
      expect(sent.single.uri.host, 'www.threads.com');
      expect(sent.single.headers['X-IG-App-ID'], '238260118697367');
    });

    test('a 400 from Threads is retried on Instagram', () async {
      // A Threads post is an Instagram media object underneath, so the same id
      // is worth asking Instagram about before giving up on the user.
      final service = serviceAnswering([400, 200], body: _oneImageBody);
      final post =
          await service.fetchPost('https://www.threads.com/@a/post/C2QBoRaRmR1');

      expect(sent, hasLength(2));
      expect(sent[0].uri.host, 'www.threads.com');
      expect(sent[1].uri.host, 'www.instagram.com');
      expect(sent[1].headers['X-IG-App-ID'], '936619743392459');
      expect(post.items, hasLength(1));
    });

    test('an Instagram post is never retried anywhere else', () async {
      final service = serviceAnswering([400]);
      await expectLater(
        service.fetchPost('https://www.instagram.com/p/C2QBoRaRmR1/'),
        throwsA(isA<MetaPostUnavailable>()),
      );
      expect(sent, hasLength(1));
    });

    test('a redirect is a missing session, not a bad post', () async {
      final service = serviceAnswering([302]);
      await expectLater(
        service.fetchPost('https://www.threads.com/@a/post/C2QBoRaRmR1'),
        throwsA(isA<MetaAuthRequired>()),
      );
      // Not worth a second request: signed out is signed out on both.
      expect(sent, hasLength(1));
    });

    test('both refusing is reported with the status', () async {
      final service = serviceAnswering([400, 400]);
      await expectLater(
        service.fetchPost('https://www.threads.com/@a/post/C2QBoRaRmR1'),
        throwsA(
          isA<MetaPostUnavailable>().having(
            (e) => e.message,
            'message',
            allOf(contains('Threads'), contains('400')),
          ),
        ),
      );
      expect(sent, hasLength(2));
    });
  });
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
        'https://www.threads.com/@zuck/post/C2QBoRaRmR1/',
        'https://www.threads.com/@zuck/post/C2QBoRaRmR1/media',
        // Routes Meta has not invented yet. The marker list was a guess about
        // the future, and a wrong guess told the user their link was not a
        // post — which they could do nothing about.
        'https://www.threads.com/@zuck/thread/C2QBoRaRmR1',
        'https://www.threads.com/@zuck/C2QBoRaRmR1',
        // Note there is no /share/ link here. That one is a redirect token,
        // not a post code — see the share-link group below.
      ]) {
        expect(MetaPostService.shortcodeOf(url), 'C2QBoRaRmR1', reason: url);
      }
    });

    test('a link with no post in it still finds nothing', () {
      // The fallback must not turn a handle or a route word into a post id.
      for (final url in [
        'https://www.threads.com/@zuck',
        'https://www.threads.com/',
        'https://www.threads.com/search',
        'https://www.threads.com/@a.very.long.handle.here',
      ]) {
        expect(MetaPostService.shortcodeOf(url), isNull, reason: url);
      }
    });

    test('a failed link says which part it could not read', () async {
      // "Does not point at a post" was unactionable for the user and
      // undiagnosable from a bug report.
      final service = MetaPostService(pageReader: (_) async => null);
      await expectLater(
        service.fetchPost('https://www.threads.com/@zuck'),
        throwsA(
          isA<MetaPostUnavailable>().having(
            (e) => e.message,
            'message',
            allOf(contains('Threads'), contains('/@zuck')),
          ),
        ),
      );
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

test('each site is sent its own app id', () {
      // Instagram's id sent to threads.com is answered with a 400, which is
      // exactly what "Threads answered with status 400" was. Both values are
      // read out of the sites' own pages, not guessed.
      expect(
        MetaPostService.appIdFor(SocialPlatform.threads),
        '238260118697367',
      );
      expect(
        MetaPostService.appIdFor(SocialPlatform.instagram),
        '936619743392459',
      );
      expect(
        MetaPostService.appIdFor(SocialPlatform.threads),
        isNot(MetaPostService.appIdFor(SocialPlatform.instagram)),
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

  group('Threads share links', () {
    // The two links that produced "status 400", and what a browser resolves
    // them to. Nine and ten characters where a post code is eleven.
    const shareA = 'https://www.threads.com/share/BAT3nujVYV/';
    const shareB = 'https://www.threads.com/share/_mVneEOYZ/';
    const postA = 'https://www.threads.com/@findsbyhadria/post/DcvLupWjoWV';

    test('a share link is recognised as one', () {
      expect(MetaPostService.isShareLink(shareA), isTrue);
      expect(MetaPostService.isShareLink(shareB), isTrue);
      expect(MetaPostService.isShareLink(postA), isFalse);
      expect(
        MetaPostService.isShareLink('https://www.instagram.com/p/ABC/'),
        isFalse,
      );
      expect(MetaPostService.isShareLink('https://www.threads.com/share'), isFalse);
    });

    test('a share token is never mistaken for a post code', () {
      // The whole bug. The loose path scan would have returned the token
      // happily, and the media id built from it asks for a post nobody
      // requested — which Threads answers with a 400.
      expect(MetaPostService.shortcodeOf(shareA), isNull);
      expect(MetaPostService.shortcodeOf(shareB), isNull);
    });

    test('a share token decodes to nothing like a media id', () {
      // Kept as a check on the reasoning, not just the code: a real code is
      // eleven characters and nineteen digits.
      final token = MetaPostService.mediaIdOf('BAT3nujVYV')!;
      final real = MetaPostService.mediaIdOf('DcvLupWjoWV')!;
      expect(token.toString().length, 17);
      expect(real.toString().length, 19);
    });

    test('a share link is resolved before anything is asked of the API', () async {
      RequestOptions? sent;
      final dio = Dio(
        BaseOptions(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      dio.httpClientAdapter = _ScriptedAdapter((options) {
        sent = options;
        return ResponseBody.fromString(_oneImageBody, 200, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
      });

      var asked = '';
      final service = MetaPostService(
        dio: dio,
        pageReader: (_) async => null,
        linkResolver: (shareUrl) async {
          asked = shareUrl;
          return postA;
        },
      );

      final post = await service.fetchPost(shareA);

      expect(asked, shareA);
      // The id in the request is the resolved post's, not the share token's.
      expect(sent!.uri.path, contains('3976448580000843157'));
      expect(post.items, hasLength(1));
    });

    test('an unresolvable share link says what to do instead', () async {
      final service = MetaPostService(
        pageReader: (_) async => null,
        linkResolver: (_) async => null,
      );
      await expectLater(
        service.fetchPost(shareA),
        throwsA(
          allOf(
            // Emphatically not an auth error. Resolving happens in a browser
            // holding whatever session the user has, so signing in again
            // changes nothing — and offering to is the loop.
            isNot(isA<MetaAuthRequired>()),
            isA<MetaPostUnavailable>()
                .having((e) => e.message, 'message', contains('post link'))
                .having((e) => e.isFinal, 'isFinal', isTrue),
          ),
        ),
      );
    });

    test('a post link is never sent to the resolver', () async {
      var resolverRan = false;
      final dio = Dio(
        BaseOptions(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      dio.httpClientAdapter = _ScriptedAdapter(
        (_) => ResponseBody.fromString(_oneImageBody, 200, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        }),
      );
      final service = MetaPostService(
        dio: dio,
        pageReader: (_) async => null,
        linkResolver: (_) async {
          resolverRan = true;
          return null;
        },
      );

      await service.fetchPost(postA);
      expect(resolverRan, isFalse, reason: 'a browser trip for nothing');
    });
  });

  group('reading a post out of its own page', () {
    // Shaped like a real Threads page: the post that was asked for, sitting
    // among the related posts that surround it.
    String pageWith(String wantedCode) => jsonEncode({
      'items': [
        {
          'code': wantedCode,
          'media_type': 2,
          'image_versions2': {
            'candidates': [
              {'url': 'https://cdn/cover.jpg', 'width': 1080, 'height': 1920},
            ],
          },
          'video_versions': [
            {'url': 'https://cdn/wanted.mp4', 'width': 1080, 'height': 1920},
          ],
        },
      ],
    });

    test('the page reply goes through the same parser as the API', () async {
      final service = MetaPostService(
        pageReader: (request) async => pageWith(request.shortcode),
        linkResolver: (_) async => null,
      );
      final post = await service.fetchPostFromPage(
        'https://www.threads.com/@a/post/DcvLupWjoWV',
      );

      expect(post.items.single.isVideo, isTrue);
      expect(post.items.single.url, 'https://cdn/wanted.mp4');
      expect(post.items.single.thumbnail, 'https://cdn/cover.jpg');
    });

    test('the reader is told which post to take', () async {
      // A Threads post page embeds around eighteen media objects and only one
      // is the post that was asked for. Without the code, the reader would
      // take whichever came first and download a stranger's post.
      MetaPageRequest? seen;
      final service = MetaPostService(
        pageReader: (request) async {
          seen = request;
          return pageWith(request.shortcode);
        },
        linkResolver: (_) async => null,
      );
      await service.fetchPostFromPage(
        'https://www.threads.com/@a/post/DcvLupWjoWV',
      );

      expect(seen!.shortcode, 'DcvLupWjoWV');
      expect(seen!.postUrl, 'https://www.threads.com/t/DcvLupWjoWV');
      expect(seen!.appId, '238260118697367');
      expect(seen!.mediaId.toString(), '3976448580000843157');
    });

    test('an Instagram post asks Instagram, on its own page', () async {
      MetaPageRequest? seen;
      final service = MetaPostService(
        pageReader: (request) async {
          seen = request;
          return pageWith(request.shortcode);
        },
        linkResolver: (_) async => null,
      );
      await service.fetchPostFromPage('https://www.instagram.com/p/DHqXk_ZSAWk/');

      expect(seen!.postUrl, 'https://www.instagram.com/p/DHqXk_ZSAWk/');
      expect(seen!.appId, '936619743392459');
    });

    test('a page with nothing in it is not a sign-in problem', () async {
      // The page carries a public post's media with no session at all, so
      // finding nothing there is a failure — not a reason to send the user to
      // a sign-in screen and back for the same result.
      final service = MetaPostService(
        pageReader: (_) async => null,
        linkResolver: (_) async => null,
      );
      await expectLater(
        service.fetchPostFromPage('https://www.threads.com/@a/post/DcvLupWjoWV'),
        throwsA(
          allOf(
            isNot(isA<MetaAuthRequired>()),
            isA<MetaPostUnavailable>(),
          ),
        ),
      );
    });

    test('a share link is resolved before the page is opened', () async {
      String? opened;
      final service = MetaPostService(
        pageReader: (request) async {
          opened = request.postUrl;
          return pageWith(request.shortcode);
        },
        linkResolver: (_) async =>
            'https://www.threads.com/@findsbyhadria/post/DcvLupWjoWV',
      );
      await service.fetchPostFromPage(
        'https://www.threads.com/share/BAT3nujVYV/',
      );

      expect(opened, 'https://www.threads.com/t/DcvLupWjoWV');
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

const _oneImageBody =
    '{"items":[{"media_type":1,"image_versions2":{"candidates":'
    '[{"url":"https://cdn/i.jpg","width":1440,"height":1800}]}}]}';

/// Answers each request from a script instead of the network.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.answer);

  final ResponseBody Function(RequestOptions options) answer;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => answer(options);

  @override
  void close({bool force = false}) {}
}
