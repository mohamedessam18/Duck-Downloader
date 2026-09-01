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



}
