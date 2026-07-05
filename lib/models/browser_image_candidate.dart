import 'download_models.dart';

class BrowserImageCandidate {
  const BrowserImageCandidate({
    required this.url,
    this.width,
    this.height,
    this.source = 'browser',
    this.isPreview = false,
    this.order,
    this.slideIndex,
    this.title,
    this.thumbnail,
    this.isVideo = false,
  });

  final String url;
  final int? width;
  final int? height;
  final String source;
  final bool isPreview;
  final int? order;
  final int? slideIndex;
  final String? title;
  final String? thumbnail;
  final bool isVideo;

  int get area => (width ?? 0) * (height ?? 0);

  PlaylistItem toPlaylistItem(int index) {
    return PlaylistItem(
      url: url,
      title: title ?? 'Image $index',
      thumbnail: thumbnail ?? url,
      width: width,
      height: height,
      source: source,
      isPreview: isPreview,
      isVideo: isVideo,
    );
  }

  factory BrowserImageCandidate.fromJson(Map<String, dynamic> json) {
    return BrowserImageCandidate(
      url: json['url']?.toString() ?? '',
      width: _readInt(json['width']),
      height: _readInt(json['height']),
      source: json['source']?.toString() ?? 'browser',
      isPreview: json['isPreview'] == true,
      order: _readInt(json['order']),
      slideIndex: _readInt(json['slideIndex']),
      title: json['title']?.toString(),
      thumbnail: json['thumbnail']?.toString(),
      isVideo: json['isVideo'] == true,
    );
  }

  static List<BrowserImageCandidate> normalizeAll(Iterable<dynamic> raw) {
    final byUrl = <String, BrowserImageCandidate>{};
    final firstOrderByUrl = <String, int>{};
    var fallbackOrder = 0;

    for (final item in raw) {
      if (item is! Map) continue;
      final candidate = BrowserImageCandidate.fromJson(
        Map<String, dynamic>.from(item),
      )._normalized(fallbackOrder++);
      if (candidate == null || candidate._shouldReject) continue;

      firstOrderByUrl.putIfAbsent(candidate.url, () => candidate.order ?? 0);
      final previous = byUrl[candidate.url];
      if (previous == null || candidate._score > previous._score) {
        byUrl[candidate.url] = candidate.copyWith(
          order: firstOrderByUrl[candidate.url],
        );
      }
    }

    final list = byUrl.values.toList();
    list.sort((a, b) {
      final slideCompare = _nullableCompare(a.slideIndex, b.slideIndex);
      if (slideCompare != 0) return slideCompare;
      return (a.order ?? 0).compareTo(b.order ?? 0);
    });
    return list;
  }

  BrowserImageCandidate copyWith({
    String? url,
    int? width,
    int? height,
    String? source,
    bool? isPreview,
    int? order,
    int? slideIndex,
    String? title,
    String? thumbnail,
    bool? isVideo,
  }) {
    return BrowserImageCandidate(
      url: url ?? this.url,
      width: width ?? this.width,
      height: height ?? this.height,
      source: source ?? this.source,
      isPreview: isPreview ?? this.isPreview,
      order: order ?? this.order,
      slideIndex: slideIndex ?? this.slideIndex,
      title: title ?? this.title,
      thumbnail: thumbnail ?? this.thumbnail,
      isVideo: isVideo ?? this.isVideo,
    );
  }

  BrowserImageCandidate? _normalized(int fallbackOrder) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    return BrowserImageCandidate(
      url: uri.toString(),
      width: width,
      height: height,
      source: source,
      isPreview: isPreview || _looksPreviewSource(source),
      order: order ?? fallbackOrder,
      slideIndex: slideIndex,
      title: title,
      thumbnail: thumbnail,
      isVideo: isVideo,
    );
  }

  bool get _shouldReject {
    final lower = url.toLowerCase();
    if (lower.startsWith('data:') || lower.startsWith('blob:')) return true;
    if (lower.contains('profile_pic') || lower.contains('s150x150')) {
      return true;
    }
    if (lower.contains('/profile_images/') || lower.contains('emoji')) {
      return true;
    }
    if (lower.contains('/static/') ||
        lower.contains('/assets/') ||
        lower.contains('rsrc.php') ||
        lower.contains('logo') ||
        lower.contains('spinner') ||
        lower.contains('loading') ||
        lower.contains('icon') ||
        lower.contains('avatar') ||
        lower.contains('badge') ||
        lower.contains('button') ||
        lower.contains('favicon') ||
        lower.contains('pixel') ||
        lower.contains('spacer') ||
        lower.contains('tracker') ||
        lower.contains('analytics') ||
        lower.contains('transparent') ||
        lower.contains('blank')) {
      return true;
    }
    if (width != null && height != null) {
      if (width! > 0 && height! > 0) {
        if (width! < 150 || height! < 150) return true;
        final squareish = (width! - height!).abs() <= 4;
        if (squareish && _looksPreviewSource(source)) return true;
      }
    }
    return false;
  }

  int get _score {
    final trusted = _sourceRank(source);
    return (100 - trusted) * 100000000 + area;
  }

  static int? _readInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static int _nullableCompare(int? a, int? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  static int _sourceRank(String source) {
    final lower = source.toLowerCase();
    if (lower.contains('page_data')) return 0;
    if (lower.contains('srcset')) return 1;
    if (lower.contains('img')) return 2;
    if (lower.contains('resource')) return 3;
    if (lower.contains('meta')) return 5;
    return 4;
  }

  static bool _looksPreviewSource(String source) {
    final lower = source.toLowerCase();
    return lower.contains('meta') ||
        lower.contains('og:') ||
        lower.contains('twitter:') ||
        lower.contains('embed');
  }
}

class LockedBrowserRequest {
  const LockedBrowserRequest({required this.url, required this.platform});

  final String url;
  final String platform;
}
