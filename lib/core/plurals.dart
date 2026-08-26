/// Counts written the way a person would write them.
///
/// "1 items" in the folder browser, and "Moved 1 file(s)" after a move, are
/// the two shapes this replaces. The second is the worse of the two: `(s)` is
/// what a string writes when nobody decided what it should say, and the user
/// is left doing the grammar.
///
/// English only, and deliberately so. The moment these strings reach the
/// localisation files this helper should give way to ICU plurals, which handle
/// the Arabic cases (dual, and a separate form for 3-10) that no amount of
/// "add an s" ever will.
String plural(int count, String singular, [String? plural]) {
  return '$count ${count == 1 ? singular : (plural ?? '${singular}s')}';
}
