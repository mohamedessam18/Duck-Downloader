import 'package:dio/dio.dart';
import 'package:duck_downloader/services/reddit_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves canned Reddit listing JSON so the parser can be exercised without
/// touching the network.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.body);

  final String body;
  String? requestedPath;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedPath = options.uri.toString();
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String _listing({
  required bool overEighteen,
  String? fallbackUrl,
  bool hasAudio = true,
  String? imageUrl,
  int? height,
}) {
  final media = fallbackUrl == null
      ? 'null'
      : '''
        {"reddit_video": {
          "fallback_url": "$fallbackUrl",
          "has_audio": $hasAudio,
          "height": ${height ?? 720},
          "width": 1280,
          "duration": 42
        }}''';
  final urlOverride = imageUrl == null ? '' : '"url_overridden_by_dest": "$imageUrl",';
  return '''
[
  {"kind": "Listing", "data": {"children": [
    {"kind": "t3", "data": {
      "title": "A post",
      "over_18": $overEighteen,
      "thumbnail": "https://b.thumbs.redditmedia.com/x.jpg",
      $urlOverride
      "secure_media": $media
    }}
  ]}},
  {"kind": "Listing", "data": {"children": []}}
]''';
}

RedditService _serviceFor(String body, {_StubAdapter? adapter}) {
  final dio = Dio();
  dio.httpClientAdapter = adapter ?? _StubAdapter(body);
  return RedditService(dio: dio);
}

void main() {
  group('RedditService.isRedditUrl', () {
    test('matches every Reddit link shape', () {
      expect(
        RedditService.isRedditUrl('https://www.reddit.com/r/x/comments/abc/t/'),
        isTrue,
      );
      expect(RedditService.isRedditUrl('https://redd.it/abc'), isTrue);
      expect(RedditService.isRedditUrl('https://v.redd.it/abc'), isTrue);
      expect(RedditService.isRedditUrl('https://example.com/reddit'), isFalse);
    });
  });

  test('reports NSFW posts so callers can block before fetching media', () async {
    final service = _serviceFor(
      _listing(overEighteen: true, fallbackUrl: 'https://v.redd.it/a/DASH_720.mp4'),
    );
    final post = await service.fetchPost('https://www.reddit.com/r/x/comments/a/t/');

    expect(post, isNotNull);
    expect(post!.isNsfw, isTrue);

    // extractMetadata refuses outright, so an NSFW post cannot be downloaded
    // even if a caller forgets the separate adult-content check.
    final metadata = await service.extractMetadata(
      'https://www.reddit.com/r/x/comments/a/t/',
    );
    expect(metadata, isNull);
  });

  test('builds video metadata with the matching DASH audio track', () async {
    final service = _serviceFor(
      _listing(
        overEighteen: false,
        fallbackUrl: 'https://v.redd.it/abc/DASH_1080.mp4?source=fallback',
        height: 1080,
      ),
    );
    final metadata = await service.extractMetadata(
      'https://www.reddit.com/r/x/comments/a/t/',
    );

    expect(metadata, isNotNull);
    expect(metadata!.platform, 'Reddit');
    expect(metadata.qualities.single.label, '1080p');
    // The query string must be stripped or the CDN rejects the request.
    expect(metadata.qualities.single.id, 'https://v.redd.it/abc/DASH_1080.mp4');
    // Reddit serves audio separately; without it the download is silent.
    expect(metadata.audioFormats.single.id, contains('DASH_AUDIO'));
    expect(metadata.duration, '0:42');
  });

  test('omits the audio track when the post has none', () async {
    final service = _serviceFor(
      _listing(
        overEighteen: false,
        fallbackUrl: 'https://v.redd.it/abc/DASH_720.mp4',
        hasAudio: false,
      ),
    );
    final metadata = await service.extractMetadata(
      'https://www.reddit.com/r/x/comments/a/t/',
    );

    expect(metadata!.audioFormats, isEmpty);
  });

  test('builds image metadata for picture posts', () async {
    final service = _serviceFor(
      _listing(overEighteen: false, imageUrl: 'https://i.redd.it/abc.png'),
    );
    final metadata = await service.extractMetadata(
      'https://www.reddit.com/r/x/comments/a/t/',
    );

    expect(metadata!.qualities.single.ext, 'png');
    expect(metadata.qualities.single.id, 'https://i.redd.it/abc.png');
  });

  test('requests the .json endpoint with query strings stripped', () async {
    final adapter = _StubAdapter(
      _listing(overEighteen: false, imageUrl: 'https://i.redd.it/abc.png'),
    );
    final service = _serviceFor('', adapter: adapter);
    await service.fetchPost(
      'https://www.reddit.com/r/x/comments/a/t/?utm_source=share',
    );

    expect(adapter.requestedPath, 'https://www.reddit.com/r/x/comments/a/t.json');
  });

  test('treats a SFW crosspost of NSFW media as NSFW', () async {
    const body = '''
[
  {"kind": "Listing", "data": {"children": [
    {"kind": "t3", "data": {
      "title": "Crosspost",
      "over_18": false,
      "crosspost_parent_list": [
        {"title": "Original", "over_18": true,
         "secure_media": {"reddit_video": {
           "fallback_url": "https://v.redd.it/a/DASH_480.mp4",
           "has_audio": true, "height": 480, "width": 854, "duration": 10}}}
      ]
    }}
  ]}}
]''';
    final service = _serviceFor(body);
    final post = await service.fetchPost('https://www.reddit.com/r/x/comments/a/t/');

    expect(post!.isNsfw, isTrue);
  });
}
