import 'package:duck_downloader/models/download_models.dart';
import 'package:duck_downloader/state/storage_summary.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadItem file(
  String id, {
  required int mb,
  DownloadType type = DownloadType.video,
  DateTime? deletedAt,
  DownloadStatus status = DownloadStatus.completed,
}) {
  return DownloadItem(
    id: id,
    url: 'https://example.com/$id',
    title: id,
    platform: 'Example',
    type: type,
    filePath: '/tmp/$id',
    createdAt: DateTime.utc(2026),
    status: status,
    progress: 100,
    favorite: false,
    fileSizeBytes: mb * 1024 * 1024,
    deletedAt: deletedAt,
  );
}

void main() {
  group('what is taking the room', () {
    test('adds up per kind', () {
      final summary = StorageSummary.of([
        file('v1', mb: 100),
        file('v2', mb: 50),
        file('a1', mb: 10, type: DownloadType.audio),
        file('i1', mb: 2, type: DownloadType.image),
      ]);

      expect(summary.slices.map((s) => s.labelKey), [
        'videosTab',
        'audiosTab',
        'imagesTab',
      ]);
      expect(summary.slices.first.count, 2);
      expect(summary.slices.first.bytes, 150 * 1024 * 1024);
      expect(summary.totalBytes, 162 * 1024 * 1024);
    });

    test('a kind with nothing in it is not a row', () {
      final summary = StorageSummary.of([file('v1', mb: 5)]);
      expect(summary.slices, hasLength(1));
      expect(summary.slices.single.labelKey, 'videosTab');
    });

    test('the biggest come first, which is the point of the screen', () {
      final summary = StorageSummary.of([
        file('small', mb: 1),
        file('huge', mb: 900),
        file('medium', mb: 40),
      ]);
      expect(summary.largest.map((e) => e.id), ['huge', 'medium', 'small']);
    });

    test('the list is capped', () {
      final summary = StorageSummary.of([
        for (var i = 0; i < 30; i++) file('f$i', mb: i + 1),
      ], largestCount: 5);
      expect(summary.largest, hasLength(5));
      expect(summary.largest.first.id, 'f29');
    });

    test('deleted files are counted apart, not lost', () {
      // The trash is still holding space on the phone, so leaving it out would
      // make this total disagree with the phone's own storage settings — but
      // it is also the one part the user can get back instantly and on
      // purpose, so it is not mixed in with the rest.
      final summary = StorageSummary.of([
        file('kept', mb: 100),
        file('binned', mb: 60, deletedAt: DateTime.utc(2026, 5)),
      ]);

      expect(summary.slices.single.bytes, 100 * 1024 * 1024);
      expect(summary.trashBytes, 60 * 1024 * 1024);
      expect(summary.trashCount, 1);
      expect(summary.totalBytes, 160 * 1024 * 1024);
    });

    test('a deleted file is not offered as a big file to delete', () {
      final summary = StorageSummary.of([
        file('kept', mb: 10),
        file('binned', mb: 900, deletedAt: DateTime.utc(2026, 5)),
      ]);
      expect(summary.largest.map((e) => e.id), ['kept']);
    });

    test('a download still running is not counted', () {
      final summary = StorageSummary.of([
        file('done', mb: 10),
        file('running', mb: 900, status: DownloadStatus.downloading),
      ]);
      expect(summary.totalBytes, 10 * 1024 * 1024);
    });

    test('an empty library is empty, not a crash', () {
      final summary = StorageSummary.of(const []);
      expect(summary.isEmpty, isTrue);
      expect(summary.totalBytes, 0);
      expect(summary.slices, isEmpty);
      expect(summary.largest, isEmpty);
    });

    test('a file with no recorded size counts as nothing, not as null', () {
      final summary = StorageSummary.of([
        DownloadItem(
          id: 'old',
          url: 'https://example.com/old',
          title: 'old',
          platform: 'Example',
          type: DownloadType.video,
          filePath: '/tmp/old',
          createdAt: DateTime.utc(2026),
          status: DownloadStatus.completed,
          progress: 100,
          favorite: false,
        ),
      ]);
      expect(summary.totalBytes, 0);
      expect(summary.slices.single.count, 1);
    });
  });

  group('a size a person can read', () {
    test('picks the unit someone would say out loud', () {
      expect(formatBytes(0), '0 MB');
      expect(formatBytes(900), '900 B');
      expect(formatBytes(5 * 1024), '5 KB');
      expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
      expect(formatBytes((1.4 * 1024 * 1024 * 1024).round()), '1.4 GB');
    });

    test('never a negative', () {
      expect(formatBytes(-5), '0 MB');
    });
  });
}
