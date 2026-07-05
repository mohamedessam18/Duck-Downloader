import 'package:duck_downloader/models/browser_image_candidate.dart';
import 'package:duck_downloader/models/download_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('download item round-trips through desktop-shaped json', () {
    final item = DownloadItem(
      id: '1',
      url: 'https://example.com/video',
      title: 'Example',
      platform: 'Example',
      type: DownloadType.video,
      createdAt: DateTime.utc(2026),
      status: DownloadStatus.queued,
      progress: 0,
      favorite: false,
      thumbnail: 'https://example.com/thumb.jpg',
      quality: '720p',
    );

    final decoded = DownloadItem.fromJson(item.toJson());

    expect(decoded.id, '1');
    expect(decoded.type, DownloadType.video);
    expect(decoded.status, DownloadStatus.queued);
    expect(decoded.quality, '720p');
    expect(decoded.savedToGallery, isFalse);
    expect(decoded.savedToMusic, isFalse);
    expect(decoded.externalSaveError, isNull);
  });

  test('download item reads legacy json without external save fields', () {
    final decoded = DownloadItem.fromJson({
      'id': 'legacy',
      'url': 'https://example.com/video',
      'title': 'Legacy',
      'platform': 'Example',
      'type': 'video',
      'createdAt': DateTime.utc(2026).toIso8601String(),
      'status': 'completed',
      'progress': 100,
      'favorite': false,
    });

    expect(decoded.savedToGallery, isFalse);
    expect(decoded.savedToMusic, isFalse);
    expect(decoded.externalSaveError, isNull);
  });

  test('playlist item reads image provenance metadata', () {
    final item = PlaylistItem.fromJson({
      'url': 'https://cdninstagram.com/full.jpg',
      'title': 'Image 1',
      'thumbnail': 'https://cdninstagram.com/full.jpg',
      'width': 853,
      'height': 1280,
      'source': 'instagram_api',
      'isPreview': false,
    });

    expect(item.url, 'https://cdninstagram.com/full.jpg');
    expect(item.width, 853);
    expect(item.height, 1280);
    expect(item.source, 'instagram_api');
    expect(item.isPreview, isFalse);
  });

  test('browser image candidates prefer full-size resources over previews', () {
    final candidates = BrowserImageCandidate.normalizeAll([
      {
        'url': 'https://instagram.com/preview.jpg',
        'width': 615,
        'height': 614,
        'source': 'meta_preview',
        'isPreview': true,
      },
      {
        'url': 'https://scontent.cdninstagram.com/full.jpg',
        'width': 853,
        'height': 1280,
        'source': 'img_srcset',
      },
      {
        'url': 'https://scontent.cdninstagram.com/avatar.jpg',
        'width': 150,
        'height': 150,
        'source': 'img',
      },
    ]);

    expect(candidates, hasLength(1));
    expect(candidates.single.url, 'https://scontent.cdninstagram.com/full.jpg');
    expect(candidates.single.isPreview, isFalse);
    expect(candidates.single.toPlaylistItem(1).url, candidates.single.url);
  });

  test('browser image candidates keep discovery order after dedupe', () {
    final candidates = BrowserImageCandidate.normalizeAll([
      {
        'url': 'https://cdninstagram.com/first.jpg',
        'width': 853,
        'height': 1280,
        'source': 'img_srcset',
        'order': 0,
        'slideIndex': 0,
      },
      {
        'url': 'https://cdninstagram.com/second.jpg',
        'width': 853,
        'height': 1280,
        'source': 'img_srcset',
        'order': 1,
        'slideIndex': 1,
      },
      {
        'url': 'https://cdninstagram.com/first.jpg',
        'width': 1200,
        'height': 1800,
        'source': 'page_data',
        'order': 5,
        'slideIndex': 0,
      },
    ]);

    expect(candidates.map((item) => item.url), [
      'https://cdninstagram.com/first.jpg',
      'https://cdninstagram.com/second.jpg',
    ]);
    expect(candidates.first.width, 1200);
    expect(candidates.first.order, 0);
  });

  test('browser image candidates use slide order before size order', () {
    final candidates = BrowserImageCandidate.normalizeAll([
      {
        'url': 'https://cdninstagram.com/slide-2.jpg',
        'width': 2000,
        'height': 2000,
        'source': 'img_srcset',
        'order': 0,
        'slideIndex': 2,
      },
      {
        'url': 'https://cdninstagram.com/slide-1.jpg',
        'width': 853,
        'height': 1280,
        'source': 'img_srcset',
        'order': 1,
        'slideIndex': 1,
      },
    ]);

    expect(candidates.map((item) => item.url), [
      'https://cdninstagram.com/slide-1.jpg',
      'https://cdninstagram.com/slide-2.jpg',
    ]);
  });
}
