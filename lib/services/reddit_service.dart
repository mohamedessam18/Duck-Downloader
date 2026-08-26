import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/download_models.dart';

/// What Reddit's public JSON endpoint told us about a post.
class RedditPost {
  const RedditPost({
    required this.title,
    required this.isNsfw,
    required this.isVideo,
    this.thumbnail,
    this.videoUrl,
    this.audioUrl,
    this.imageUrl,
    this.height,
    this.width,
    this.durationSeconds,
  });

  final String title;

  /// Reddit's own `over_18` marking, set per post and inherited from NSFW
  /// subreddits. This is the authoritative signal — far more reliable than
  /// guessing from the URL, because reddit.com itself is a perfectly ordinary
  /// domain that happens to host adult subreddits.
  final bool isNsfw;

  final bool isVideo;
  final String? thumbnail;

  /// v.redd.it video track. Reddit serves DASH, so this carries **no audio**.
  final String? videoUrl;

  /// Matching audio track, when the post has one.
  final String? audioUrl;

  final String? imageUrl;
  final int? height;
  final int? width;
  final int? durationSeconds;

  bool get hasSeparateAudio => audioUrl != null;
}

/// Reads Reddit posts through the public `.json` endpoint.
///
/// Reddit is unusual among the supported platforms: the domain is mainstream,
/// but individual posts and whole subreddits can be adult. Every read here
/// therefore returns [RedditPost.isNsfw] so the caller can block before any
/// media is fetched.
class RedditService {
  RedditService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              headers: const {
                // Reddit rejects requests without a real User-Agent, and
                // rate-limits aggressively when one looks like a bot.
                'User-Agent':
                    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                    'AppleWebKit/537.36 (KHTML, like Gecko) '
                    'Chrome/122.0.0.0 Safari/537.36',
                'Accept': 'application/json',
              },
              followRedirects: true,
              maxRedirects: 5,
            ),
          );

  final Dio _dio;

  static bool isRedditUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('reddit.com') ||
        lower.contains('redd.it') ||
        lower.contains('reddit.app.link');
  }

  /// Fetches post details, or null if the URL is not a readable Reddit post.
  Future<RedditPost?> fetchPost(String url) async {
    final jsonUrl = _toJsonUrl(url);
    if (jsonUrl == null) return null;

    try {
      final response = await _dio.get<dynamic>(jsonUrl);
      final data = _decode(response.data);
      if (data == null) return null;
      return _parsePost(data);
    } catch (error) {
      debugPrint('RedditService: could not read $jsonUrl — $error');
      return null;
    }
  }

  /// Builds [MediaMetadata] for the download UI.
  ///
  /// Returns null for NSFW posts so callers cannot accidentally proceed; use
  /// [fetchPost] directly when the block needs to be reported to the user.
  Future<MediaMetadata?> extractMetadata(String url) async {
    final post = await fetchPost(url);
    if (post == null || post.isNsfw) return null;
    return buildMetadata(url, post);
  }

  MediaMetadata? buildMetadata(String url, RedditPost post) {
    if (post.isVideo && post.videoUrl != null) {
      final height = post.height;
      return MediaMetadata(
        url: url,
        title: post.title,
        platform: 'Reddit',
        thumbnail: post.thumbnail,
        duration: post.durationSeconds == null
            ? null
            : _formatDuration(post.durationSeconds!),
        qualities: [
          FormatInfo(
            id: post.videoUrl!,
            label: height != null ? '${height}p' : 'Best',
            ext: 'mp4',
            height: height,
            width: post.width,
          ),
        ],
        audioFormats: post.hasSeparateAudio
            ? [FormatInfo(id: post.audioUrl!, label: 'Audio', ext: 'm4a')]
            : const [],
      );
    }

    if (post.imageUrl != null) {
      return MediaMetadata(
        url: url,
        title: post.title,
        platform: 'Reddit',
        thumbnail: post.thumbnail ?? post.imageUrl,
        qualities: [
          FormatInfo(
            id: post.imageUrl!,
            label: 'Original Image',
            ext: _extensionOf(post.imageUrl!),
          ),
        ],
        audioFormats: const [],
      );
    }

    return null;
  }

  /// Converts a post permalink into its `.json` form.
  String? _toJsonUrl(String url) {
    var cleaned = url.trim();
    if (cleaned.isEmpty) return null;
    // Drop query and fragment — `?utm_source=share` breaks the .json suffix.
    cleaned = cleaned.split('?').first.split('#').first;
    if (cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    if (cleaned.isEmpty) return null;
    if (cleaned.endsWith('.json')) return cleaned;
    return '$cleaned.json';
  }

  dynamic _decode(dynamic body) {
    if (body is String) {
      try {
        return jsonDecode(body);
      } catch (_) {
        return null;
      }
    }
    return body;
  }

  RedditPost? _parsePost(dynamic decoded) {
    // A post listing is `[postListing, commentsListing]`; a shortlink that
    // redirected to a subreddit gives a bare listing instead.
    Map<String, dynamic>? postData;
    if (decoded is List && decoded.isNotEmpty) {
      postData = _firstChild(decoded.first);
    } else if (decoded is Map) {
      postData = _firstChild(decoded);
    }
    if (postData == null) return null;

    final crosspost = postData['crosspost_parent_list'];
    if (crosspost is List && crosspost.isNotEmpty && crosspost.first is Map) {
      // Crossposts carry the media on the original post, but NSFW must be
      // taken from either side — a SFW crosspost of NSFW media is still NSFW.
      final parent = Map<String, dynamic>.from(crosspost.first as Map);
      final parentPost = _readPost(parent);
      if (parentPost != null) {
        return RedditPost(
          title: postData['title']?.toString() ?? parentPost.title,
          isNsfw: parentPost.isNsfw || postData['over_18'] == true,
          isVideo: parentPost.isVideo,
          thumbnail: parentPost.thumbnail,
          videoUrl: parentPost.videoUrl,
          audioUrl: parentPost.audioUrl,
          imageUrl: parentPost.imageUrl,
          height: parentPost.height,
          width: parentPost.width,
          durationSeconds: parentPost.durationSeconds,
        );
      }
    }

    return _readPost(postData);
  }

  Map<String, dynamic>? _firstChild(dynamic listing) {
    if (listing is! Map) return null;
    final data = listing['data'];
    if (data is! Map) return null;
    final children = data['children'];
    if (children is! List || children.isEmpty) return null;
    final first = children.first;
    if (first is! Map) return null;
    final childData = first['data'];
    if (childData is! Map) return null;
    return Map<String, dynamic>.from(childData);
  }

  RedditPost? _readPost(Map<String, dynamic> data) {
    final title = data['title']?.toString() ?? 'Reddit post';
    final isNsfw = data['over_18'] == true;
    final thumbnail = _usableThumbnail(data['thumbnail']?.toString());

    final video = _readVideo(data);
    if (video != null) {
      return RedditPost(
        title: title,
        isNsfw: isNsfw,
        isVideo: true,
        thumbnail: thumbnail,
        videoUrl: video.videoUrl,
        audioUrl: video.audioUrl,
        height: video.height,
        width: video.width,
        durationSeconds: video.durationSeconds,
      );
    }

    final imageUrl = _readImage(data);
    return RedditPost(
      title: title,
      isNsfw: isNsfw,
      isVideo: false,
      thumbnail: thumbnail,
      imageUrl: imageUrl,
    );
  }

  _RedditVideo? _readVideo(Map<String, dynamic> data) {
    for (final key in ['secure_media', 'media']) {
      final media = data[key];
      if (media is! Map) continue;
      final redditVideo = media['reddit_video'];
      if (redditVideo is! Map) continue;

      final fallback = redditVideo['fallback_url']?.toString();
      if (fallback == null || fallback.isEmpty) continue;

      // fallback_url looks like https://v.redd.it/<id>/DASH_720.mp4?source=fallback
      final videoUrl = fallback.split('?').first;
      return _RedditVideo(
        videoUrl: videoUrl,
        audioUrl: redditVideo['has_audio'] == false
            ? null
            : _audioUrlFor(videoUrl),
        height: (redditVideo['height'] as num?)?.toInt(),
        width: (redditVideo['width'] as num?)?.toInt(),
        durationSeconds: (redditVideo['duration'] as num?)?.toInt(),
      );
    }
    return null;
  }

  /// Reddit keeps the audio track beside the video in the same DASH folder.
  String? _audioUrlFor(String videoUrl) {
    final slash = videoUrl.lastIndexOf('/');
    if (slash <= 0) return null;
    return '${videoUrl.substring(0, slash)}/DASH_AUDIO_128.mp4';
  }

  String? _readImage(Map<String, dynamic> data) {
    final overridden = data['url_overridden_by_dest']?.toString();
    if (overridden != null && _looksLikeImage(overridden)) return overridden;

    final preview = data['preview'];
    if (preview is Map) {
      final images = preview['images'];
      if (images is List && images.isNotEmpty && images.first is Map) {
        final source = (images.first as Map)['source'];
        if (source is Map) {
          final url = source['url']?.toString();
          // Reddit HTML-escapes preview URLs.
          if (url != null && url.isNotEmpty) return url.replaceAll('&amp;', '&');
        }
      }
    }

    final url = data['url']?.toString();
    if (url != null && _looksLikeImage(url)) return url;
    return null;
  }

  bool _looksLikeImage(String url) {
    final clean = url.toLowerCase().split('?').first;
    return clean.endsWith('.jpg') ||
        clean.endsWith('.jpeg') ||
        clean.endsWith('.png') ||
        clean.endsWith('.gif') ||
        clean.endsWith('.webp');
  }

  /// Reddit uses the sentinels "self", "default", "nsfw" and "spoiler" in the
  /// thumbnail field instead of a URL.
  String? _usableThumbnail(String? value) {
    if (value == null || value.isEmpty) return null;
    if (!value.startsWith('http')) return null;
    return value.replaceAll('&amp;', '&');
  }

  String _extensionOf(String url) {
    final clean = url.split('?').first;
    final dot = clean.lastIndexOf('.');
    if (dot < 0 || dot == clean.length - 1) return 'jpg';
    return clean.substring(dot + 1).toLowerCase();
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remaining = seconds % 60;
    return '$minutes:${remaining.toString().padLeft(2, '0')}';
  }

  void dispose() => _dio.close();
}

class _RedditVideo {
  const _RedditVideo({
    required this.videoUrl,
    this.audioUrl,
    this.height,
    this.width,
    this.durationSeconds,
  });

  final String videoUrl;
  final String? audioUrl;
  final int? height;
  final int? width;
  final int? durationSeconds;
}
