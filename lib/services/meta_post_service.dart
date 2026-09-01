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
    MetaLinkResolver? linkResolver,
  }) : _sessions = sessions ?? const PlatformSessionStore(),
       pageReader = pageReader ?? readThroughPage,
       linkResolver = linkResolver ?? resolveThroughPage,
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

  /// How the last-resort tier reaches the platform. Injectable so the
  /// fallback can be tested without a WebView.
  final MetaPageReader pageReader;

  /// Turns a share link into the post it points at. Also injectable.
  final MetaLinkResolver linkResolver;

  /// The real post URL behind [url], or [url] when it is already one.
  Future<String> resolved(String url) async {
    if (!isShareLink(url)) return url;
    final target = await linkResolver(url.trim());
    if (target == null || target.trim().isEmpty) {
      throw const MetaAuthRequired(
        'Could not open that share link. Try the post link itself.',
      );
    }
    return target;
  }

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

  /// True for the link the Threads share button produces.
  ///
  /// `threads.com/share/<token>` is a redirect, and the token is not a post
  /// code: it is nine or ten characters where a code is eleven, and the number
  /// it decodes to is seventeen digits where a media id is nineteen. Feeding
  /// it to the media API asks for a post that does not exist, which is what
  /// "Threads would not open this post (status 400)" was.
  static bool isShareLink(String url) {
    final segments = Uri.tryParse(url.trim())?.pathSegments ?? const [];
    return segments.length >= 2 && segments.first.toLowerCase() == 'share';
  }

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
    // Refused outright rather than allowed to fall through to the loose scan
    // below, which would happily return the share token and produce a media id
    // for a post that was never asked for.
    if (isShareLink(url)) return null;

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
  Future<MetaPost> fetchPost(String rawUrl) async {
    // A share link has to become a post link before anything else can happen.
    final url = await resolved(rawUrl);
    final platform = platformOf(url);
    if (platform == null) {
      throw const MetaPostUnavailable(
        'That link is not a post Duck can read.',
        isFinal: true,
      );
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
        isFinal: true,
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
      throw MetaPostUnavailable(
        'This $name post no longer exists.',
        isFinal: true,
      );
    }
    if (status != 200) {
      // Carries what the server actually said. A bare status number is what
      // three rounds of guessing at this were built on: it says a request was
      // refused without ever saying why, so the only way forward was to change
      // something and ask the user to try again.
      final said = _shortReason(response.data?.toString());
      throw MetaPostUnavailable(
        '$name would not open this post (status $status)'
        '${said.isEmpty ? '' : ': $said'}',
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

  /// The server's own explanation, short enough to read on a phone.
  ///
  /// Meta answers a refusal with a small JSON object carrying a `message`.
  /// Anything else is truncated rather than dropped — an HTML login page in
  /// the first eighty characters still says more than a bare status code.
  static String _shortReason(String? body) {
    final text = body?.trim() ?? '';
    if (text.isEmpty) return '';
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        for (final key in ['message', 'error_message', 'error', 'title']) {
          final value = decoded[key];
          if (value is String && value.trim().isNotEmpty) return value.trim();
        }
      }
    } catch (_) {}
    final flat = text.replaceAll(RegExp(r'\s+'), ' ');
    return flat.length <= 80 ? flat : '${flat.substring(0, 80)}…';
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

/// Everything the last-resort tier needs to identify one post.
class MetaPageRequest {
  const MetaPageRequest({
    required this.postUrl,
    required this.mediaId,
    required this.appId,
    required this.shortcode,
  });

  final String postUrl;
  final BigInt mediaId;

  /// The app id belonging to [postUrl]'s host. The two sites do not share one.
  final String appId;

  /// Which post to take out of the page.
  ///
  /// Load-bearing: a Threads post page embeds eighteen media objects, only one
  /// of which is the post that was asked for. The rest are "related posts",
  /// and taking the first thing that looks like media downloads somebody
  /// else's.
  final String shortcode;
}

/// Fetches the media JSON for one post, from inside a real page.
typedef MetaPageReader = Future<String?> Function(MetaPageRequest request);

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
  Future<MetaPost> fetchPostFromPage(String rawUrl) async {
    final url = await resolved(rawUrl);
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
      MetaPageRequest(
        postUrl: MetaPostService.canonicalPostUrl(platform, shortcode),
        mediaId: mediaId,
        appId: MetaPostService.appIdFor(platform),
        shortcode: shortcode,
      ),
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

/// Turns a share link into the post URL it points at.
typedef MetaLinkResolver = Future<String?> Function(String shareUrl);

/// Opens the share link offscreen and reads where it settles.
///
/// It has to be a browser. `threads.com/share/<token>` answers a plain request
/// with 200 and the app shell — no redirect, no canonical link, and none of the
/// crawler user agents Meta usually serves Open Graph tags to get anything
/// either. The post URL only exists after the page's own JavaScript has run,
/// which is why it is read back out of the rendered document.
Future<String?> resolveThroughPage(String shareUrl) async {
  final loaded = Completer<void>();
  final headless = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(shareUrl)),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      domStorageEnabled: true,
      thirdPartyCookiesEnabled: true,
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

    // The canonical link is written by the page script, so it appears some
    // time after the load event rather than with it.
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline)) {
      final result = await headless.webViewController?.evaluateJavascript(
        source:
            '(function () {'
            '  var l = document.querySelector("link[rel=canonical]");'
            '  var o = document.querySelector("meta[property=\'og:url\']");'
            '  return (l && l.href) || (o && o.content) || "";'
            '})()',
      );
      final found = result?.toString().trim() ?? '';
      // Ignore the share URL echoing itself back before the script has run.
      if (found.isNotEmpty && !MetaPostService.isShareLink(found)) return found;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return null;
  } on TimeoutException {
    return null;
  } finally {
    await headless.dispose();
  }
}

/// The last resort: open the post offscreen and take the media out of it.
///
/// Two ways, in one trip, because the two sites do not answer the same way.
///
/// The first is the media API called from inside the page, which inherits the
/// page's origin, cookies and headers — the request Instagram's own front end
/// makes.
///
/// The second is the page's own data. A Threads post page ships the media as
/// JSON in its script tags, in the same shape the API returns, and a public
/// post carries it with no session at all. That matters more than it sounds:
/// no library reads Threads — yt-dlp has had an open request since 2023 and
/// gallery-dl does not list it — so there is nothing to fall back on, and the
/// page is the only thing Meta cannot quietly change the shape of without
/// breaking its own site.
///
/// The node is matched on its `code`. A post page embeds around eighteen media
/// objects and only one of them is the post that was asked for; the rest are
/// related posts, so taking the first match downloads a stranger's.
Future<String?> readThroughPage(MetaPageRequest request) async {
  final loaded = Completer<void>();
  final headless = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(request.postUrl)),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      domStorageEnabled: true,
      thirdPartyCookiesEnabled: true,
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
      functionBody: _pageExtractor,
      arguments: {
        'mediaId': request.mediaId.toString(),
        'appId': request.appId,
        'code': request.shortcode,
      },
    );
    if (result?.error != null) return null;
    final value = result?.value?.toString().trim() ?? '';
    return value.isEmpty || value == 'null' ? null : value;
  } on TimeoutException {
    return null;
  } finally {
    await headless.dispose();
  }
}

/// Runs inside the post's own page. Returns `{"items":[node]}` or null.
const _pageExtractor = r'''
  const wanted = (obj) =>
    obj && typeof obj === "object" &&
    (obj.image_versions2 || obj.video_versions || obj.carousel_media);

  // 1. The request the site's own front end makes.
  try {
    const response = await fetch("/api/v1/media/" + mediaId + "/info/", {
      headers: { "X-IG-App-ID": appId },
      credentials: "include",
    });
    if (response.ok) {
      const text = await response.text();
      const parsed = JSON.parse(text);
      if (parsed && parsed.items && parsed.items.length) return text;
    }
  } catch (e) {}

  // 2. The data the page was rendered from. Bounded so a deep graph cannot
  //    spin here; the post's own node sits near the top of it.
  let budget = 200000;
  for (const script of document.querySelectorAll('script[type="application/json"]')) {
    let data;
    try { data = JSON.parse(script.textContent); } catch (e) { continue; }
    const stack = [data];
    while (stack.length && budget-- > 0) {
      const node = stack.pop();
      if (!node || typeof node !== "object") continue;
      if (node.code === code && wanted(node)) {
        return JSON.stringify({ items: [node] });
      }
      for (const key in node) stack.push(node[key]);
    }
  }
  return null;
''';
