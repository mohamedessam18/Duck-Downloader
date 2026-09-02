import '../models/download_models.dart';

/// How a library list is ordered.
enum LibrarySort { newest, oldest, largest, smallest, name }

extension LibrarySortLabel on LibrarySort {
  /// The l10n key for this order's name.
  String get labelKey => switch (this) {
    LibrarySort.newest => 'sortNewest',
    LibrarySort.oldest => 'sortOldest',
    LibrarySort.largest => 'sortLargest',
    LibrarySort.smallest => 'sortSmallest',
    LibrarySort.name => 'sortName',
  };
}

/// Searching and ordering a library list.
///
/// Its own file, and free of any widget, because every list in the app wants
/// the same two things and they had none: the order was `createdAt` descending
/// written out at each call site, and there was no search anywhere at all.
/// Pure functions can be checked against a list rather than through a screen.
class LibraryView {
  const LibraryView({this.query = '', this.sort = LibrarySort.newest});

  /// What the user typed. Empty means everything.
  final String query;

  final LibrarySort sort;

  LibraryView copyWith({String? query, LibrarySort? sort}) =>
      LibraryView(query: query ?? this.query, sort: sort ?? this.sort);

  bool get isSearching => query.trim().isNotEmpty;

  /// The list as the user asked to see it.
  List<DownloadItem> apply(List<DownloadItem> items) {
    final matched = isSearching
        ? items.where((item) => matches(item, query)).toList()
        : List<DownloadItem>.from(items);
    matched.sort(_compare);
    return matched;
  }

  int _compare(DownloadItem a, DownloadItem b) {
    return switch (sort) {
      LibrarySort.newest => b.createdAt.compareTo(a.createdAt),
      LibrarySort.oldest => a.createdAt.compareTo(b.createdAt),
      // Ties broken by date so the order is stable rather than incidental:
      // two files of the same size must not swap places between rebuilds.
      LibrarySort.largest => _bySize(b, a, tie: () => b.createdAt.compareTo(a.createdAt)),
      LibrarySort.smallest => _bySize(a, b, tie: () => b.createdAt.compareTo(a.createdAt)),
      LibrarySort.name => _byName(a, b),
    };
  }

  static int _bySize(DownloadItem a, DownloadItem b, {required int Function() tie}) {
    final result = (a.fileSizeBytes ?? 0).compareTo(b.fileSizeBytes ?? 0);
    return result != 0 ? result : tie();
  }

  static int _byName(DownloadItem a, DownloadItem b) {
    final result = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    return result != 0 ? result : b.createdAt.compareTo(a.createdAt);
  }

  /// Whether [item] answers [query].
  ///
  /// Matched loosely on purpose. Someone looking for a file they saved months
  /// ago remembers a word from the title, not its punctuation or the platform
  /// it came from — and on this app half the titles are Arabic, where the same
  /// word is spelled several ways depending on the keyboard.
  static bool matches(DownloadItem item, String query) {
    final needle = _normalise(query);
    if (needle.isEmpty) return true;
    final haystack = [
      item.title,
      item.platform,
      item.artist ?? '',
      item.album ?? '',
    ].map(_normalise).join(' ');
    return needle.split(' ').where((word) => word.isNotEmpty).every(
      haystack.contains,
    );
  }

  /// Folds away the differences that stop a search matching what was meant.
  ///
  /// Arabic alef comes in four shapes and taa marbuta in two, and which one a
  /// title carries depends on whoever typed it. Diacritics and the tatweel
  /// stretch are decoration. Case and punctuation go for the same reason.
  static String _normalise(String value) {
    final buffer = StringBuffer();
    for (final rune in value.toLowerCase().runes) {
      final char = String.fromCharCode(rune);
      buffer.write(switch (char) {
        'أ' || 'إ' || 'آ' || 'ٱ' => 'ا',
        'ى' => 'ي',
        'ة' => 'ه',
        'ؤ' => 'و',
        'ئ' => 'ي',
        // Harakat, tanween, shadda, sukun and the tatweel.
        _ when rune >= 0x064B && rune <= 0x0652 => '',
        'ـ' => '',
        _ when _isSeparator(char) => ' ',
        _ => char,
      });
    }
    return buffer.toString().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  }

  static bool _isSeparator(String char) {
    return !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(char);
  }
}
