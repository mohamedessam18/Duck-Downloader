/// Choosing which of several streams to download.
///
/// Its own file, and free of any YouTube type, because the version that lived
/// inline was wrong for a long time without anyone being able to see it. It
/// read `sortByVideoQuality().last` under a comment saying "highest
/// available" — but that sort puts the best stream first, so `.last` is the
/// worst one. Every YouTube video download took 144p no matter which quality
/// the user picked. A pure function can be checked against a list of numbers.
library;

/// The highest stream at or below [ceiling], or the smallest when none fit.
///
/// [heightOf] keeps this independent of the stream type. A null [ceiling]
/// means "the best there is".
T? bestAtOrBelow<T>(
  Iterable<T> streams,
  int Function(T) heightOf, {
  int? ceiling,
}) {
  if (streams.isEmpty) return null;

  T? best;
  for (final stream in streams) {
    final height = heightOf(stream);
    if (ceiling != null && height > ceiling) continue;
    if (best == null || height > heightOf(best)) best = stream;
  }
  if (best != null) return best;

  // Everything on offer is above the ceiling — a 4K-only upload when 360p was
  // asked for. Returning null here would fail the download outright, so take
  // the smallest thing available instead.
  var smallest = streams.first;
  for (final stream in streams) {
    if (heightOf(stream) < heightOf(smallest)) smallest = stream;
  }
  return smallest;
}
