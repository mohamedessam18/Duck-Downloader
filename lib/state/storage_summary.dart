import '../models/download_models.dart';

/// One slice of what Duck is holding.
class StorageSlice {
  const StorageSlice({
    required this.labelKey,
    required this.bytes,
    required this.count,
  });

  final String labelKey;
  final int bytes;
  final int count;
}

/// What the app is keeping, and where it went.
///
/// A downloader's library is the reason a phone fills up, and until now the
/// app could not answer the only question that matters when it does: what is
/// taking the room. The numbers come from the size recorded when each download
/// finished, so reading this costs nothing on disk.
class StorageSummary {
  const StorageSummary({
    required this.slices,
    required this.largest,
    required this.trashBytes,
    required this.trashCount,
  });

  /// Videos, audio and images, in that order, skipping any that are empty.
  final List<StorageSlice> slices;

  /// The biggest files, largest first — where the room actually went.
  final List<DownloadItem> largest;

  /// Held by files waiting to be erased. Counted apart, because it is the one
  /// part the user can get back instantly and on purpose.
  final int trashBytes;
  final int trashCount;

  int get totalBytes =>
      slices.fold(0, (sum, slice) => sum + slice.bytes) + trashBytes;

  bool get isEmpty => totalBytes == 0;

  /// Reads a library into a summary.
  ///
  /// [items] is everything the app knows about, deleted rows included: the
  /// trash is part of what the phone is holding, and leaving it out would make
  /// the total disagree with the storage settings the user can also see.
  static StorageSummary of(List<DownloadItem> items, {int largestCount = 10}) {
    var trashBytes = 0;
    var trashCount = 0;
    final byType = <DownloadType, List<DownloadItem>>{
      DownloadType.video: [],
      DownloadType.audio: [],
      DownloadType.image: [],
    };

    for (final item in items) {
      if (item.status != DownloadStatus.completed) continue;
      final bytes = item.fileSizeBytes ?? 0;
      if (item.isDeleted) {
        trashBytes += bytes;
        trashCount++;
        continue;
      }
      byType[item.type]?.add(item);
    }

    final slices = <StorageSlice>[];
    for (final entry in byType.entries) {
      final bytes = entry.value.fold(
        0,
        (sum, item) => sum + (item.fileSizeBytes ?? 0),
      );
      if (entry.value.isEmpty) continue;
      slices.add(
        StorageSlice(
          labelKey: switch (entry.key) {
            DownloadType.video => 'videosTab',
            DownloadType.audio => 'audiosTab',
            DownloadType.image => 'imagesTab',
          },
          bytes: bytes,
          count: entry.value.length,
        ),
      );
    }

    final ranked = [for (final list in byType.values) ...list]
      ..sort(
        (a, b) => (b.fileSizeBytes ?? 0).compareTo(a.fileSizeBytes ?? 0),
      );

    return StorageSummary(
      slices: slices,
      largest: ranked.take(largestCount).toList(),
      trashBytes: trashBytes,
      trashCount: trashCount,
    );
  }
}

/// A size a person can read.
///
/// Whole gigabytes past a gigabyte and one decimal below it: "1.4 GB" is the
/// number someone acts on, and "1,503,238,553 bytes" is not.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  const kb = 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  return '$bytes B';
}
