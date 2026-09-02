import 'package:duck_downloader/models/download_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('an update keeps every field', () {
    /// Every field of a saved row, none of them left at its default.
    DownloadItem full({DateTime? deletedAt}) => DownloadItem(
      id: 'row-1',
      url: 'https://example.com/clip',
      title: 'A clip',
      platform: 'Instagram',
      thumbnail: 'https://cdn/thumb.jpg',
      quality: '1080p',
      type: DownloadType.video,
      filePath: '/files/clip.mp4',
      createdAt: DateTime.utc(2026, 5, 1),
      status: DownloadStatus.completed,
      progress: 100,
      favorite: true,
      savedToGallery: true,
      savedToMusic: true,
      isPrivate: false,
      externalSaveError: 'none',
      artist: 'Someone',
      album: 'An album',
      fileSizeBytes: 4096,
      deletedAt: deletedAt,
      trashedPath: deletedAt == null ? null : '/trash/row-1.mp4',
      originalPath: deletedAt == null ? null : '/files/clip.mp4',
    );

    test('a round trip through json loses nothing', () {
      final restored = DownloadItem.fromJson(full().toJson());
      expect(restored.toJson(), full().toJson());
    });

    test('the deletion survives being written and read', () {
      // The bug this exists for: deleting stopped working the moment
      // `deletedAt` existed, because the store merged updates field by field
      // from a hand-written list and the new field was not on it. The row came
      // back undeleted and the file never left the library.
      final deleted = full(deletedAt: DateTime.utc(2026, 6, 1));
      final restored = DownloadItem.fromJson(deleted.toJson());

      expect(restored.isDeleted, isTrue);
      expect(restored.deletedAt, DateTime.utc(2026, 6, 1));
      expect(restored.trashedPath, '/trash/row-1.mp4');
      expect(restored.originalPath, '/files/clip.mp4');
    });

    test('restoring clears all three, which copyWith alone cannot do', () {
      // Passing null to copyWith reads as "leave it alone" — the one shape
      // that cannot express a restore.
      final deleted = full(deletedAt: DateTime.utc(2026, 6, 1));
      final restored = deleted.copyWith(clearDeleted: true);

      expect(restored.isDeleted, isFalse);
      expect(restored.trashedPath, isNull);
      expect(restored.originalPath, isNull);
      // And nothing else moved.
      expect(restored.title, deleted.title);
      expect(restored.favorite, deleted.favorite);
      expect(restored.fileSizeBytes, deleted.fileSizeBytes);
    });

    test('the recorded size survives too', () {
      final restored = DownloadItem.fromJson(full().toJson());
      expect(restored.fileSizeBytes, 4096);
    });
  });

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
