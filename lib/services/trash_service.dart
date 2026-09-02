import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where deleted files wait before they are really gone.
///
/// Deleting used to call `File.delete` and that was that: one mis-tap on a
/// 128 MB download that took ten minutes to fetch, and it was gone with no
/// way back. A week is long enough to notice the mistake and short enough
/// that the storage comes back on its own.
///
/// The folder is inside the app's own documents directory and carries a
/// `.nomedia`, so nothing here shows up in the phone's gallery or in Duck's
/// own folder browser. A deleted file that still appears in a media list has
/// not really been deleted as far as the person who deleted it is concerned.
class TrashService {
  const TrashService();

  /// How long a deleted file is kept.
  static const retention = Duration(days: 7);

  static const _folderName = '.duck-trash';

  Future<Directory> _folder() async {
    final root = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(root.path, 'Duck Downloader', _folderName));
    if (!await folder.exists()) {
      await folder.create(recursive: true);
      // Android's media scanner skips any directory holding this file, which
      // is what keeps deleted downloads out of the gallery.
      await File(p.join(folder.path, '.nomedia')).create();
    }
    return folder;
  }

  /// Moves [filePath] into the trash and returns its new location.
  ///
  /// Returns null when there was nothing to move, so the caller can still drop
  /// the row: a record pointing at a file that is already gone is not a reason
  /// to refuse.
  Future<String?> moveIn(String? filePath, {required String id}) async {
    if (filePath == null) return null;
    final source = File(filePath);
    if (!await source.exists()) return null;

    final folder = await _folder();
    // Named by the row's id, so two files that shared a name cannot collide
    // and quietly overwrite one another in here.
    final target = p.join(folder.path, '$id${p.extension(filePath)}');
    try {
      return (await source.rename(target)).path;
    } on FileSystemException {
      // A rename across devices fails, which happens when the file was saved
      // to external storage. Copy and remove instead.
      await source.copy(target);
      await source.delete();
      return target;
    }
  }

  /// Puts a file back where it came from.
  ///
  /// Returns null when the original location is no longer writable, which the
  /// caller reports rather than pretending the restore worked.
  Future<String?> moveOut(String? trashedPath, String? originalPath) async {
    if (trashedPath == null || originalPath == null) return null;
    final source = File(trashedPath);
    if (!await source.exists()) return null;

    final target = File(originalPath);
    try {
      await target.parent.create(recursive: true);
      // Never overwrite. Something else may live at the old path by now, and
      // restoring is not a reason to destroy it.
      final free = await _freePath(originalPath);
      return (await source.rename(free)).path;
    } on FileSystemException {
      try {
        final free = await _freePath(originalPath);
        await source.copy(free);
        await source.delete();
        return free;
      } catch (_) {
        return null;
      }
    }
  }

  Future<void> erase(String? trashedPath) async {
    if (trashedPath == null) return;
    try {
      final file = File(trashedPath);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Deletes anything left behind that no row claims any more.
  ///
  /// Restores and purges can be interrupted — the app is killed, the write
  /// fails — and without this the folder would only ever grow.
  Future<void> sweepOrphans(Set<String> claimed) async {
    try {
      final folder = await _folder();
      await for (final entity in folder.list()) {
        if (entity is! File) continue;
        if (p.basename(entity.path) == '.nomedia') continue;
        if (claimed.contains(entity.path)) continue;
        await entity.delete();
      }
    } catch (_) {}
  }

  static Future<String> _freePath(String desired) async {
    if (!await File(desired).exists()) return desired;
    final dir = p.dirname(desired);
    final ext = p.extension(desired);
    final base = p.basenameWithoutExtension(desired);
    for (var n = 1; n < 1000; n++) {
      final candidate = p.join(dir, '$base ($n)$ext');
      if (!await File(candidate).exists()) return candidate;
    }
    return p.join(dir, '$base ${DateTime.now().millisecondsSinceEpoch}$ext');
  }
}
