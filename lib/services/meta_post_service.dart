import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/meta_post.dart';
import 'platform_sessions.dart';

/// Reads an Instagram or Threads post on the user's own device, with their
/// own session.
///
/// One class for both because they are one product underneath. Threads runs on
/// Instagram's infrastructure: the same base-64 shortcodes, the same numeric
/// media ids, the same `/api/v1/media/{id}/info/` reply — so the same parser
/// reads both, and a bug fixed for one is fixed for the other. Threads has no
/// Reels, but a Threads post can still hold a single video, and that shape is
/// already the same shape.
///
/// The same reasoning as YouTube for doing it here at all. Meta blocks
/// datacentre addresses hard, so a request from the backend is answered as a
/// stranger's no matter whose cookies it carries, while the identical request
/// from the phone is answered as the person who is signed in. It also means
/// the session never leaves the device for the common case.
class MetaPostService {
  MetaPostService({
    Dio? dio,
    PlatformSessionStore? sessions,
    MetaPageReader? pageReader,
  }) : _sessions = sessions ?? const PlatformSessionStore(),
       pageReader = pageReader ?? readThroughPage,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              // Unauthenticated requests are answered with a 302 to the login
              // page. Following it would turn a clear "you are signed out"
              // into an HTML page that parses as nothing, so the redirect is
              // the answer rather than something to chase.
              followRedirects: false,
              validateStatus: (status) => status != null && status < 500,
            ),
          );

  final Dio _dio;
  final PlatformSessionStore _sessions;

  /// How the last-resort tier reaches Instagram. Injectable so the
  /// fallback can be tested without a WebView.
  final MetaPageReader pageReader;

  /// The web client id each site's own front end sends.
  ///
  /// Public, and required — without it the API answers every request as
  /// unauthenticated. They are *not* interchangeable: sending Instagram's id
  /// to threads.com is answered with a 400, which is what "Threads answered
  /// with status 400" was. Read out of each site's own page rather than
  /// guessed.
  static const _instagramAppId = '936619743392459';
  static const _threadsAppId = '238260118697367';

  static String appIdFor(SocialPlatform platform) =>
      platform == SocialPlatform.threads ? _threadsAppId : _instagramAppId;

  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  static const _shortcodeAlphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

  /// The two platforms this reads, or null for anything else.
  static SocialPlatform? platformOf(String url) {
    final platform = profileForUrl(url)?.platform;
    return platform == SocialPlatform.instagram ||
            platform == SocialPlatform.threads
        ? platform
        : null;
  }

  static bool handles(String url) => platformOf(url) != null;

  /// Where the API call is made and the page is opened.
  ///
  /// threads.net now answers a post URL with a 301 to threads.com, so calling
  /// the old domain costs a redirect on every request — and the API client
  /// deliberately does not follow redirects, because a redirect is how a
  /// signed-out reply arrives.
  static String originFor(SocialPlatform platform) =>
      platform == SocialPlatform.threads
      ? 'https://www.threads.com'
      : 'https://www.instagram.com';

  /// The page that shows this post, on its own platform.
  ///
  /// Threads answers `/@handle/post/<code>` too, but the handle is not always
  /// in the link the user pasted — `/t/<code>` carries no handle at all — and
  /// this form works without one.
  static String canonicalPostUrl(SocialPlatform platform, String shortcode) =>
      platform == SocialPlatform.threads
      ? '${originFor(platform)}/t/$shortcode'
      : '${originFor(platform)}/p/$shortcode/';

  /// Path segments that name a route rather than a post.
  static const _routeSegments = {
    'p', 'reel', 'reels', 'tv', 'post', 't', 'media', 'share', 'stories',
  };

  /// The post id in a link from either platform.
  ///
  /// Instagram spells it `/p/`, `/reel/`, `/reels/` or `/tv/`; Threads spells
  /// it `/post/` under an `@handle`, or `/t/` in a short link. The code itself
  /// is the same base-64 in both.
  ///
  /// The known markers are tried first, and then the path is read for a
  /// segment that simply looks like a code. Meta adds and renames these routes
  /// without warning — a list of the ones that existed when this was written
  /// turns every new one into "that link does not point at a post", which is
  /// both wrong and impossible for the user to do anything about.
  static String? shortcodeOf(String url) {
    final path = Uri.tryParse(url.trim())?.path ?? '';

    final marked = RegExp(
      r'/(?:p|reel|reels|tv|post|t)/([A-Za-z0-9_-]+)',
    ).firstMatch(path);
    if (marked != null) return marked.group(1);

    // A code is a run of base-64 characters long enough not to be a word, and
    // an @handle is never one.
    final code = RegExp(r'^[A-Za-z0-9_-]{8,}$');
    for (final segment in path.split('/').reversed) {
      if (segment.isEmpty || segment.startsWith('@')) continue;
      if (_routeSegments.contains(segment.toLowerCase())) continue;
      if (code.hasMatch(segment)) return segment;
    }
    return null;
  }

  /// Instagram's numeric media id, which the shortcode is a base-64 spelling
  /// of. The API is addressed by the number, never by the shortcode.
  static BigInt? mediaIdOf(String shortcode) {
    if (shortcode.isEmpty) return null;
    var id = BigInt.zero;
    for (final char in shortcode.split('')) {
      final index = _shortcodeAlphabet.indexOf(char);
      if (index < 0) return null;
      id = id * BigInt.from(64) + BigInt.from(index);
    }
    return id;
  }

  /// Turns a stored Netscape jar into a `Cookie:` header.
  static String cookieHeader(String? netscapeJar) {
    if (netscapeJar == null || netscapeJar.trim().isEmpty) return '';
    final pairs = <String, String>{};
    for (final line in netscapeJar.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final fields = trimmed.split('\t');
      if (fields.length < 7) continue;
      final name = fields[5].trim();
      if (name.isEmpty) continue;
      pairs[name] = fields[6].trim();
    }
    return pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// Reads the post at [url].
  ///
  /// Throws [MetaAuthRequired] when Instagram wants a session, and
  /// [MetaPostUnavailable] when there is no such post. The caller needs
  /// to tell those apart: only one of them is worth offering a sign-in for.
  Future<MetaPost> fetchPost(String url) async {
    final platform = platformOf(url);
    if (platform == null) {
      throw const MetaPostUnavailable('That link is not a post Duck can read.');
    }
    final name = profileFor(platform).label;

    final shortcode = shortcodeOf(url);
    final mediaId = shortcode == null ? null : mediaIdOf(shortcode);
    if (shortcode == null || mediaId == null) {
      // Names the part that failed. "Does not point at a post" on its own is
      // unactionable for the user and undiagnosable for anyone reading a bug
      // report, and Meta changes these paths without notice.
      throw MetaPostUnavailable(
        'Could not find a post id in that $name link '
        '(${Uri.tryParse(url.trim())?.path ?? url}).',
      );
    }

    final cookies = cookieHeader(await _sessions.read(platform));

    var response = await _requestMediaInfo(
      origin: originFor(platform),
      appId: appIdFor(platform),
      mediaId: mediaId,
      cookies: cookies,
    );

    // A Threads post is an Instagram media object underneath, so when Threads'
    // own API will not answer for it, Instagram's is asked about the same id
    // with the same session. The Threads jar carries instagram.com cookies for
    // exactly this reason — signing into Threads goes through Instagram.
    if (platform == SocialPlatform.threads &&
        (response.statusCode == 400 || response.statusCode == 404)) {
      response = await _requestMediaInfo(
        origin: originFor(SocialPlatform.instagram),
        appId: appIdFor(SocialPlatform.instagram),
        mediaId: mediaId,
        cookies: cookies,
      );
    }

    final status = response.statusCode ?? 0;
    if (status == 302 || status == 401 || status == 403) {
      throw MetaAuthRequired(
        cookies.isEmpty
            ? '$name needs you to be signed in to open this post.'
            : '$name did not accept the saved session for this post.',
      );
    }
    if (status == 404 || status == 410) {
      throw MetaPostUnavailable('This $name post no longer exists.');
    }
    if (status != 200) {
      throw MetaPostUnavailable(
        '$name would not open this post (status $status).',
      );
    }

    final body = response.data?.toString() ?? '';
    late final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      // A login wall served as HTML rather than as a redirect.
      throw MetaAuthRequired(
        '$name returned its login page instead of the post.',
      );
    }

    final post = parseMediaInfo(decoded, shortcode);
    if (post == null || post.isEmpty) {
      throw MetaPostUnavailable(
        '$name returned no downloadable media for this post.',
      );
    }
    return post;
  }

  Future<Response<dynamic>> _requestMediaInfo({
    required String origin,
    required String appId,
    required BigInt mediaId,
    required String cookies,
  }) {
    return _dio.get<dynamic>(
      '$origin/api/v1/media/$mediaId/info/',
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'X-IG-App-ID': appId,
          'User-Agent': _userAgent,
          'Referer': '$origin/',
          'Accept': '*/*',
          if (cookies.isNotEmpty) 'Cookie': cookies,
        },
      ),
    );
  }

  /// Builds a post out of an `/media/{id}/info/` body.
  ///
  /// Separated from the request so the shapes can be tested without a session:
  /// single image, single video, a carousel of each, and the mixed carousel
  /// that is the whole reason items carry their own type.
  static MetaPost? parseMediaInfo(dynamic decoded, String shortcode) {
    if (decoded is! Map) return null;
    final items = decoded['items'];
    if (items is! List || items.isEmpty) return null;
    final root = items.first;
    if (root is! Map) return null;

    final caption = root['caption'];
    final title = caption is Map
        ? (caption['text']?.toString().trim() ?? '')
        : '';

    final media = <MetaMedia>[];
    final children = root['carousel_media'];
    if (children is List && children.isNotEmpty) {
      for (final child in children) {
        final parsed = _mediaFrom(child);
        if (parsed != null) media.add(parsed);
      }
    } else {
      final parsed = _mediaFrom(root);
      if (parsed != null) media.add(parsed);
    }

    if (media.isEmpty) return null;
    return MetaPost(
      shortcode: shortcode,
      title: title.isEmpty
          ? 'Instagram Post'
          : title.split('\n').first.trim(),
      items: media,
      thumbnail: media.first.thumbnail ?? media.first.url,
    );
  }

  /// One node — a whole post or one carousel child — as media.
  ///
  /// `media_type` is trusted over the presence of `video_versions`, then the
  /// versions are checked anyway. Instagram sends an image cover on every
  /// video, so a node that has both is a video; taking the picture because it
  /// was there is how a Reel ends up saved as a JPEG.
  static MetaMedia? _mediaFrom(dynamic node) {
    if (node is! Map) return null;

    final videos = node['video_versions'];
    final images = node['image_versions2'];
    final candidates = images is Map ? images['candidates'] : null;

    final cover = candidates is List ? _largest(candidates) : null;

    if (node['media_type'] == 2 || (videos is List && videos.isNotEmpty)) {
      final best = videos is List ? _largest(videos) : null;
      final videoUrl = best?['url']?.toString();
      if (videoUrl == null || videoUrl.isEmpty) return null;
      return MetaMedia(
        url: videoUrl,
        isVideo: true,
        width: _asInt(best?['width']),
        height: _asInt(best?['height']),
        thumbnail: cover?['url']?.toString(),
      );
    }

    final imageUrl = cover?['url']?.toString();
    if (imageUrl == null || imageUrl.isEmpty) return null;
    return MetaMedia(
      url: imageUrl,
      isVideo: false,
      width: _asInt(cover?['width']),
      height: _asInt(cover?['height']),
    );
  }

  /// The biggest rendition on offer, which is the original.
  ///
  /// Instagram lists candidates largest-first *most* of the time, so reaching
  /// for `.first` works until it does not and the user gets a thumbnail. Area
  /// does not depend on the order.
  static Map? _largest(List candidates) {
    Map? best;
    var bestArea = -1;
    for (final candidate in candidates) {
      if (candidate is! Map) continue;
      final area =
          (_asInt(candidate['width']) ?? 0) * (_asInt(candidate['height']) ?? 0);
      if (best == null || area > bestArea) {
        best = candidate;
        bestArea = area;
      }
    }
    return best;
  }

  static int? _asInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// Fetches the media JSON for one post, from inside a real page.
///
/// The app id travels with it: the page runs the same request the site's own
/// front end does, and the two sites do not share an id.
typedef MetaPageReader =
    Future<String?> Function(String postUrl, BigInt mediaId, String appId);

extension MetaPageFallback on MetaPostService {
  /// Last resort: ask Instagram's own page to fetch the post for us.
  ///
  /// This replaces a 240-line scraper that read whatever the open page
  /// happened to contain. Two things were wrong with that. It parsed the DOM,
  /// so any change to Instagram's markup broke it silently; and it read the
  /// *current* page rather than the link the user pasted, so navigating during
  /// the download changed what got downloaded.
  ///
  /// Calling `fetch` inside the page instead means the request carries the
  /// page's own origin, cookies and headers — exactly what Instagram's web app
  /// does — and the answer comes back in the same shape the direct call
  /// returns, so it goes through the same tested parser rather than a second
  /// one that can disagree with it.
  Future<MetaPost> fetchPostFromPage(String url) async {
    final platform = MetaPostService.platformOf(url);
    if (platform == null) {
      throw const MetaPostUnavailable('That link is not a post Duck can read.');
    }
    final name = profileFor(platform).label;

    final shortcode = MetaPostService.shortcodeOf(url);
    final mediaId =
        shortcode == null ? null : MetaPostService.mediaIdOf(shortcode);
    if (shortcode == null || mediaId == null) {
      throw MetaPostUnavailable('That $name link does not point at a post.');
    }

    // The page has to be the platform's own, because the whole trick is that
    // the fetch inherits *that* origin's cookies. Opening an Instagram page to
    // read a Threads post would send the request as the wrong site.
    final body = await pageReader(
      MetaPostService.canonicalPostUrl(platform, shortcode),
      mediaId,
      MetaPostService.appIdFor(platform),
    );
    if (body == null || body.trim().isEmpty) {
      throw MetaAuthRequired(
        '$name would not open this post in the app browser either.',
      );
    }

    late final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw MetaPostUnavailable(
        '$name returned something that was not a post.',
      );
    }
    final post = MetaPostService.parseMediaInfo(decoded, shortcode);
    if (post == null || post.isEmpty) {
      throw MetaPostUnavailable(
        '$name returned no downloadable media for this post.',
      );
    }
    return post;
  }
}

/// Loads the post in an offscreen WebView and calls the media API from it.
Future<String?> readThroughPage(
  String postUrl,
  BigInt mediaId,
  String appId,
) async {
  final loaded = Completer<void>();
  final headless = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(postUrl)),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      domStorageEnabled: true,
      thirdPartyCookiesEnabled: true,
      // The same plain Chrome string the sign-in screen uses. A WebView that
      // announces itself as one is served a degraded page.
      userAgent:
          'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
    ),
    onLoadStop: (_, _) {
      if (!loaded.isCompleted) loaded.complete();
    },
    onReceivedError: (_, _, _) {
      if (!loaded.isCompleted) loaded.complete();
    },
  );

  try {
    await headless.run();
    await loaded.future.timeout(const Duration(seconds: 20));

    final result = await headless.webViewController?.callAsyncJavaScript(
      functionBody:
          'const response = await fetch("/api/v1/media/" + mediaId + "/info/", {'
          '  headers: { "X-IG-App-ID": appId },'
          '  credentials: "include",'
          '});'
          'if (!response.ok) return null;'
          'return await response.text();',
      arguments: {'mediaId': mediaId.toString(), 'appId': appId},
    );
    if (result?.error != null) return null;
    return result?.value?.toString();
  } on TimeoutException {
    return null;
  } finally {
    await headless.dispose();
  }
}
