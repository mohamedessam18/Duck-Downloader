import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/instagram_post.dart';
import 'platform_sessions.dart';

/// Reads an Instagram post on the user's own device, with their own session.
///
/// The same reasoning as YouTube. Meta blocks datacentre addresses hard, so a
/// request from the backend is answered as a stranger's no matter whose
/// cookies it carries, while the identical request from the phone is answered
/// as the person who is signed in. It also means the session never leaves the
/// device for the common case.
class InstagramService {
  InstagramService({
    Dio? dio,
    PlatformSessionStore? sessions,
    InstagramPageReader? pageReader,
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
  final InstagramPageReader pageReader;

  /// Instagram's own web client id. Public, and required — without it the API
  /// answers every request as unauthenticated.
  static const _appId = '936619743392459';

  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  static const _shortcodeAlphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

  static bool isInstagramUrl(String url) =>
      profileForUrl(url)?.platform == SocialPlatform.instagram;

  /// The post id in a `/p/`, `/reel/`, `/reels/` or `/tv/` link.
  static String? shortcodeOf(String url) {
    final match = RegExp(
      r'/(?:p|reel|reels|tv)/([A-Za-z0-9_-]+)',
    ).firstMatch(Uri.tryParse(url.trim())?.path ?? '');
    return match?.group(1);
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
  /// Throws [InstagramAuthRequired] when Instagram wants a session, and
  /// [InstagramPostUnavailable] when there is no such post. The caller needs
  /// to tell those apart: only one of them is worth offering a sign-in for.
  Future<InstagramPost> fetchPost(String url) async {
    final shortcode = shortcodeOf(url);
    if (shortcode == null) {
      throw const InstagramPostUnavailable(
        'That Instagram link does not point at a post.',
      );
    }
    final mediaId = mediaIdOf(shortcode);
    if (mediaId == null) {
      throw const InstagramPostUnavailable(
        'That Instagram link does not point at a post.',
      );
    }

    final cookies = cookieHeader(
      await _sessions.read(SocialPlatform.instagram),
    );

    final response = await _dio.get<dynamic>(
      'https://www.instagram.com/api/v1/media/$mediaId/info/',
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'X-IG-App-ID': _appId,
          'User-Agent': _userAgent,
          'Referer': 'https://www.instagram.com/',
          'Accept': '*/*',
          if (cookies.isNotEmpty) 'Cookie': cookies,
        },
      ),
    );

    final status = response.statusCode ?? 0;
    if (status == 302 || status == 401 || status == 403) {
      throw InstagramAuthRequired(
        cookies.isEmpty
            ? 'Instagram needs you to be signed in to open this post.'
            : 'Instagram did not accept the saved session for this post.',
      );
    }
    if (status == 404 || status == 410) {
      throw const InstagramPostUnavailable(
        'This Instagram post no longer exists.',
      );
    }
    if (status != 200) {
      throw InstagramPostUnavailable(
        'Instagram answered with status $status for this post.',
      );
    }

    final body = response.data?.toString() ?? '';
    late final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      // A login wall served as HTML rather than as a redirect.
      throw const InstagramAuthRequired(
        'Instagram returned its login page instead of the post.',
      );
    }

    final post = parseMediaInfo(decoded, shortcode);
    if (post == null || post.isEmpty) {
      throw const InstagramPostUnavailable(
        'Instagram returned no downloadable media for this post.',
      );
    }
    return post;
  }

  /// Builds a post out of an `/media/{id}/info/` body.
  ///
  /// Separated from the request so the shapes can be tested without a session:
  /// single image, single video, a carousel of each, and the mixed carousel
  /// that is the whole reason items carry their own type.
  static InstagramPost? parseMediaInfo(dynamic decoded, String shortcode) {
    if (decoded is! Map) return null;
    final items = decoded['items'];
    if (items is! List || items.isEmpty) return null;
    final root = items.first;
    if (root is! Map) return null;

    final caption = root['caption'];
    final title = caption is Map
        ? (caption['text']?.toString().trim() ?? '')
        : '';

    final media = <InstagramMedia>[];
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
    return InstagramPost(
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
  static InstagramMedia? _mediaFrom(dynamic node) {
    if (node is! Map) return null;

    final videos = node['video_versions'];
    final images = node['image_versions2'];
    final candidates = images is Map ? images['candidates'] : null;

    final cover = candidates is List ? _largest(candidates) : null;

    if (node['media_type'] == 2 || (videos is List && videos.isNotEmpty)) {
      final best = videos is List ? _largest(videos) : null;
      final videoUrl = best?['url']?.toString();
      if (videoUrl == null || videoUrl.isEmpty) return null;
      return InstagramMedia(
        url: videoUrl,
        isVideo: true,
        width: _asInt(best?['width']),
        height: _asInt(best?['height']),
        thumbnail: cover?['url']?.toString(),
      );
    }

    final imageUrl = cover?['url']?.toString();
    if (imageUrl == null || imageUrl.isEmpty) return null;
    return InstagramMedia(
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
typedef InstagramPageReader =
    Future<String?> Function(String postUrl, BigInt mediaId);

extension InstagramPageFallback on InstagramService {
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
  Future<InstagramPost> fetchPostFromPage(String url) async {
    final shortcode = InstagramService.shortcodeOf(url);
    final mediaId =
        shortcode == null ? null : InstagramService.mediaIdOf(shortcode);
    if (shortcode == null || mediaId == null) {
      throw const InstagramPostUnavailable(
        'That Instagram link does not point at a post.',
      );
    }

    final body = await pageReader(
      'https://www.instagram.com/p/$shortcode/',
      mediaId,
    );
    if (body == null || body.trim().isEmpty) {
      throw const InstagramAuthRequired(
        'Instagram would not open this post in the app browser either.',
      );
    }

    late final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw const InstagramPostUnavailable(
        'Instagram returned something that was not a post.',
      );
    }
    final post = InstagramService.parseMediaInfo(decoded, shortcode);
    if (post == null || post.isEmpty) {
      throw const InstagramPostUnavailable(
        'Instagram returned no downloadable media for this post.',
      );
    }
    return post;
  }
}

/// Loads the post in an offscreen WebView and calls the media API from it.
Future<String?> readThroughPage(String postUrl, BigInt mediaId) async {
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
          '  headers: { "X-IG-App-ID": "936619743392459" },'
          '  credentials: "include",'
          '});'
          'if (!response.ok) return null;'
          'return await response.text();',
      arguments: {'mediaId': mediaId.toString()},
    );
    if (result?.error != null) return null;
    return result?.value?.toString();
  } on TimeoutException {
    return null;
  } finally {
    await headless.dispose();
  }
}
