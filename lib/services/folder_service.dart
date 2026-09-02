import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Folders the user makes, holding files that really move.
///
/// The Folders tab already lists what is on the phone; this is the other kind
/// — somewhere to put things, rather than a report of where they landed. A
/// download moved into one moves on disk, so it stays put after a restart,
/// after a reinstall of the library index, and when looked at from anywhere
/// else.
///
/// They live under the app's own documents directory. Shared storage would put
/// the user's own filing in the same place as the gallery's, and Duck has no
/// business creating folders in someone's photo library.
class FolderService {
  const FolderService();

  static const _root = 'Folders';

  /// Characters a folder name may not carry, because a path cannot.
  static final _illegal = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

  /// A name that can be a directory, or null when nothing usable is left.
  static String? sanitiseName(String raw) {
    final cleaned = raw
        .replaceAll(_illegal, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        // A leading dot hides the folder from the file browsers the user might
        // open it in, which is not what naming a folder is for.
        .replaceAll(RegExp(r'^\.+'), '')
        .trim();
    if (cleaned.isEmpty) return null;
    return cleaned.length <= 60 ? cleaned : cleaned.substring(0, 60).trim();
  }

  Future<Directory> _rootDir() async {
    final documents = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(documents.path, 'Duck Downloader', _root));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// The folders that exist, by name, in the order a person reads them.
  Future<List<String>> list() async {
    try {
      final root = await _rootDir();
      final names = <String>[];
      await for (final entity in root.list()) {
        if (entity is Directory) names.add(p.basename(entity.path));
      }
      names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return names;
    } catch (_) {
      return const [];
    }
  }

  /// Makes a folder and returns its name, or null when the name is unusable.
  Future<String?> create(String rawName) async {
    final name = sanitiseName(rawName);
    if (name == null) return null;
    final root = await _rootDir();
    final dir = Directory(p.join(root.path, name));
    if (!await dir.exists()) await dir.create();
    return name;
  }

  /// Renames a folder, leaving the files inside it where they are.
  ///
  /// Returns the new name, or null when it could not be done — a name already
  /// taken, or one that sanitises to nothing.
  Future<String?> rename(String from, String rawTo) async {
    final to = sanitiseName(rawTo);
    if (to == null || to == from) return null;
    final root = await _rootDir();
    final source = Directory(p.join(root.path, from));
    final target = Directory(p.join(root.path, to));
    if (!await source.exists() || await target.exists()) return null;
    await source.rename(target.path);
    return to;
  }

  /// Removes a folder. Its files are moved out first by the caller.
  Future<void> remove(String name) async {
    try {
      final root = await _rootDir();
      final dir = Directory(p.join(root.path, name));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Moves a file into [folder], or back out when [folder] is null.
  ///
  /// Returns where the file ended up, or null when there was nothing to move.
  /// [fallbackDir] is where "out" means — the place downloads normally live.
  Future<String?> move(
    String? filePath, {
    required String? folder,
    required String fallbackDir,
  }) async {
    if (filePath == null) return null;
    final source = File(filePath);
    if (!await source.exists()) return null;

    final Directory destination;
    if (folder == null) {
      destination = Directory(fallbackDir);
    } else {
      final name = sanitiseName(folder);
      if (name == null) return null;
      destination = Directory(p.join((await _rootDir()).path, name));
    }
    await destination.create(recursive: true);

    final target = await _freePath(
      p.join(destination.path, p.basename(filePath)),
    );
    if (target == filePath) return filePath;
    try {
      return (await source.rename(target)).path;
    } on FileSystemException {
      // Renaming across devices fails; a file saved to external storage lands
      // here. Copy, then remove the original.
      await source.copy(target);
      await source.delete();
      return target;
    }
  }

  /// Never overwrites. Two downloads can share a filename, and filing one
  /// away is not a reason to destroy the other.
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
