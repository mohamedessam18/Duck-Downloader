/// One downloadable thing inside an Instagram post.
class InstagramMedia {
  const InstagramMedia({
    required this.url,
    required this.isVideo,
    this.width,
    this.height,
    this.thumbnail,
  });

  /// The CDN URL of the file itself, at its original resolution.
  final String url;

  final bool isVideo;
  final int? width;
  final int? height;

  /// The cover frame, for videos. Null for images, whose [url] is the picture.
  final String? thumbnail;

  int get area => (width ?? 0) * (height ?? 0);
}

/// An Instagram post, whatever shape it happens to be.
///
/// Instagram calls all four shapes the same thing and distinguishes them with
/// `media_type` (1 image, 2 video, 8 carousel) plus, for a carousel, a
/// per-child `media_type` again. Collapsing that into one list with a flag per
/// item is what lets a post with three photos and a video download as three
/// photos and a video instead of four of whatever the user picked.
class InstagramPost {
  const InstagramPost({
    required this.shortcode,
    required this.title,
    required this.items,
    this.thumbnail,
  });

  final String shortcode;
  final String title;
  final List<InstagramMedia> items;
  final String? thumbnail;

  bool get isEmpty => items.isEmpty;
  bool get isSingle => items.length == 1;

  bool get hasVideo => items.any((item) => item.isVideo);
  bool get hasImage => items.any((item) => !item.isVideo);

  /// True when the post holds both kinds, which is the case the download
  /// options have to open on "everything as it is".
  bool get isMixed => hasVideo && hasImage;
}

/// Instagram answered, but not with a post.
///
/// Kept separate from a generic failure because the two need opposite
/// responses: a session problem is worth offering a sign-in for, and a deleted
/// post is not. Asking someone who is already signed in to sign in again — and
/// again, after that — is the loop this type exists to end.
class InstagramAuthRequired implements Exception {
  const InstagramAuthRequired(this.message);
  final String message;

  @override
  String toString() => message;
}

class InstagramPostUnavailable implements Exception {
  const InstagramPostUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}
