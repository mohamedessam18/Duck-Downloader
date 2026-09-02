import 'package:duck_downloader/models/download_models.dart';
import 'package:duck_downloader/state/library_view_mode.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadItem item(
  String title, {
  String id = '',
  int days = 0,
  int? size,
  String platform = 'Instagram',
  String? artist,
}) {
  return DownloadItem(
    id: id.isEmpty ? title : id,
    url: 'https://example.com/$title',
    title: title,
    platform: platform,
    artist: artist,
    type: DownloadType.video,
    filePath: '/tmp/$title.mp4',
    createdAt: DateTime.utc(2026, 1, 1).add(Duration(days: days)),
    status: DownloadStatus.completed,
    progress: 100,
    favorite: false,
    fileSizeBytes: size,
  );
}

List<String> titles(List<DownloadItem> items) =>
    items.map((entry) => entry.title).toList();

void main() {
  group('order', () {
    final items = [
      item('one', days: 1, size: 300),
      item('two', days: 3, size: 100),
      item('three', days: 2, size: 200),
    ];

    test('newest first is the default, as it always was', () {
      expect(titles(const LibraryView().apply(items)), ['two', 'three', 'one']);
    });

    test('oldest first', () {
      const view = LibraryView(sort: LibrarySort.oldest);
      expect(titles(view.apply(items)), ['one', 'three', 'two']);
    });

    test('largest first, which is how you find what is eating the phone', () {
      const view = LibraryView(sort: LibrarySort.largest);
      expect(titles(view.apply(items)), ['one', 'three', 'two']);
    });

    test('smallest first', () {
      const view = LibraryView(sort: LibrarySort.smallest);
      expect(titles(view.apply(items)), ['two', 'three', 'one']);
    });

    test('by name, ignoring case', () {
      const view = LibraryView(sort: LibrarySort.name);
      final mixed = [item('Beta'), item('alpha'), item('Gamma')];
      expect(titles(view.apply(mixed)), ['alpha', 'Beta', 'Gamma']);
    });

    test('files of the same size keep a stable order', () {
      // Otherwise two equal rows swap places between rebuilds, which reads as
      // the list shuffling itself.
      const view = LibraryView(sort: LibrarySort.largest);
      final tied = [
        item('older', days: 1, size: 500),
        item('newer', days: 5, size: 500),
      ];
      expect(titles(view.apply(tied)), ['newer', 'older']);
      expect(titles(view.apply(tied.reversed.toList())), ['newer', 'older']);
    });

    test('a file with no recorded size sorts last, not first', () {
      const view = LibraryView(sort: LibrarySort.largest);
      final mixed = [item('unknown'), item('known', size: 10)];
      expect(titles(view.apply(mixed)), ['known', 'unknown']);
    });

    test('sorting does not modify the list it was given', () {
      final original = [item('a', days: 1), item('b', days: 2)];
      const LibraryView(sort: LibrarySort.oldest).apply(original);
      expect(titles(original), ['a', 'b']);
    });
  });

  group('search', () {
    test('an empty query is everything', () {
      final items = [item('a'), item('b')];
      expect(const LibraryView().apply(items), hasLength(2));
      expect(const LibraryView(query: '   ').apply(items), hasLength(2));
    });

    test('matches part of a title', () {
      final items = [item('sunset over cairo'), item('a cat video')];
      expect(
        titles(const LibraryView(query: 'cairo').apply(items)),
        ['sunset over cairo'],
      );
    });

    test('every word has to appear, in any order', () {
      final items = [
        item('sunset over cairo'),
        item('cairo at noon'),
      ];
      expect(
        titles(const LibraryView(query: 'cairo sunset').apply(items)),
        ['sunset over cairo'],
      );
    });

    test('matches the platform and the artist too', () {
      final items = [
        item('clip one', platform: 'YouTube'),
        item('clip two', platform: 'Instagram', artist: 'Amr Diab'),
      ];
      expect(titles(const LibraryView(query: 'youtube').apply(items)), ['clip one']);
      expect(titles(const LibraryView(query: 'amr').apply(items)), ['clip two']);
    });

    group('Arabic, where the same word is spelled several ways', () {
      test('alef in any of its shapes finds the same file', () {
        final items = [item('احمد في الاسكندرية')];
        for (final query in ['أحمد', 'احمد', 'إحمد', 'آحمد']) {
          expect(
            const LibraryView().copyWith(query: query).apply(items),
            hasLength(1),
            reason: query,
          );
        }
      });

      test('taa marbuta and haa are the same letter to a searcher', () {
        final items = [item('رحلة الى اسوان')];
        expect(const LibraryView(query: 'رحله').apply(items), hasLength(1));
      });

      test('alef maqsura and yaa', () {
        final items = [item('على الطريق')];
        expect(const LibraryView(query: 'علي').apply(items), hasLength(1));
      });

      test('diacritics on the file do not have to be typed', () {
        final items = [item('يَسْمَعُ ءايَٰتِ')];
        expect(const LibraryView(query: 'يسمع').apply(items), hasLength(1));
      });

      test('a word the file does not have still finds nothing', () {
        final items = [item('رحلة الى اسوان')];
        expect(const LibraryView(query: 'القاهرة').apply(items), isEmpty);
      });
    });

    test('punctuation is not something anyone retypes', () {
      final items = [item('ابدأ بالصلاة الان .mp4 🤍')];
      expect(const LibraryView(query: 'ابدا بالصلاه').apply(items), hasLength(1));
    });

    test('search and order apply together', () {
      const view = LibraryView(query: 'clip', sort: LibrarySort.largest);
      final items = [
        item('clip small', size: 10),
        item('other', size: 999),
        item('clip big', size: 100),
      ];
      expect(titles(view.apply(items)), ['clip big', 'clip small']);
    });
  });
}
