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
  });
}
