import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/download_models.dart';

/// One media file as the library knows it.
///
/// Carries the size, duration and folder that MediaStore already has, so the
/// browser no longer has to `stat` every file to show them.
class DeviceMediaEntry {
  const DeviceMediaEntry({
    required this.id,
    required this.name,
    required this.path,
    required this.folderPath,
    required this.folderName,
    required this.size,
    required this.mimeType,
    required this.modified,
    required this.mediaType,
    required this.duration,
  });

  final String id;
  final String name;
  final String path;
  final String folderPath;
  final String folderName;
  final int size;
  final String? mimeType;
  final DateTime modified;

  /// MediaStore MEDIA_TYPE: 1 image, 2 video, 3 audio.
  final int mediaType;
  final Duration? duration;

  static DeviceMediaEntry? fromNative(Map<Object?, Object?> row) {
    final path = row['path'] as String?;
    if (path == null || path.isEmpty) return null;
    final folderPath = (row['folderPath'] as String?) ?? p.dirname(path);
    final durationMs = (row['duration'] as num?)?.toInt();
    return DeviceMediaEntry(
      id: '${row['id'] ?? path}',
      name: (row['name'] as String?) ?? p.basename(path),
      path: path,
      folderPath: folderPath,
      folderName: (row['folderName'] as String?) ?? p.basename(folderPath),
      size: (row['size'] as num?)?.toInt() ?? 0,
      mimeType: row['mimeType'] as String?,
      modified: DateTime.fromMillisecondsSinceEpoch(
        (row['modified'] as num?)?.toInt() ?? 0,
      ),
      mediaType: (row['type'] as num?)?.toInt() ?? 0,
      duration: durationMs == null || durationMs <= 0
          ? null
          : Duration(milliseconds: durationMs),
    );
  }

  DownloadItem toDownloadItem(DownloadType type) {
    return DownloadItem(
      id: path,
      url: path,
      title: name,
      filePath: path,
      type: type,
      quality: 'Device Media',
      createdAt: modified,
      status: DownloadStatus.completed,
      progress: 100,
      favorite: false,
      platform: 'Device',
    );
  }

  /// "4.2 MB" — the browser shows this per row.
  String get readableSize {
    if (size <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = size.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}

class DeviceMediaFolder {
  DeviceMediaFolder({
    required this.name,
    required this.path,
    required this.itemCount,
    this.coverPath,
    required this.items,
    this.entries = const [],
    this.totalBytes = 0,
    this.type,
  });

  final String name;
  final String path;
  final int itemCount;
  final String? coverPath;
  final List<DownloadItem> items;

  /// Which tab this listing belongs to, or null for a type-agnostic listing
  /// such as the move-destination picker.
  ///
  /// A folder holding photos and video appears under both tabs, and each one
  /// must show only its own half — so "which folder" is never enough to
  /// re-read a listing, and the type has to travel with it.
  final DownloadType? type;

  /// The same files with their library metadata attached.
  final List<DeviceMediaEntry> entries;
  final int totalBytes;
}

/// Outcome of an edit that may need the user's consent.
enum DeviceMediaEditResult {
  /// The file was changed.
  success,

  /// The system consent dialog was shown and the user declined.
  declined,

  /// The operation could not be attempted (missing file, name clash, …).
  failed,
}

/// An edit outcome plus, when it failed, the reason to show the user.
///
/// The native side knows things worth repeating verbatim — "Could not delete
/// 2 of 5 files", "A file with that name already exists" — and collapsing them
/// all into one generic message left the user with no idea what to do.
typedef DeviceMediaEditOutcome = ({
  DeviceMediaEditResult result,
  String? message,
});

class DeviceMediaService {
  DeviceMediaService({MethodChannel? channel, bool? hasMediaStore})
    : _channel = channel ?? const MethodChannel('duck_downloader/media'),
      _hasMediaStore = hasMediaStore ?? Platform.isAndroid;

  final MethodChannel _channel;

  /// Whether MediaStore is the source of truth on this platform.
  ///
  /// Injectable so the grouping and caching can be tested without a device;
  /// reading `Platform.isAndroid` inline made every one of these paths
  /// unreachable from a test.
  final bool _hasMediaStore;

  /// How long to wait for the system consent dialog before giving up.
  ///
  /// The native call only completes when the dialog returns through
  /// `onActivityResult`. If the activity is recreated while the dialog is up —
  /// a rotation, or the system reclaiming memory — that callback never
  /// arrives and the future would hang forever, freezing the sheet on its
  /// progress bar with no way back.
  static const _consentTimeout = Duration(minutes: 2);

  /// Renames a file in the user's own media library.
  ///
  /// Under scoped storage the app cannot silently modify media it did not
  /// create, so Android 11+ shows a system consent sheet first; declining is a
  /// normal outcome rather than an error, hence the tri-state result.
  Future<DeviceMediaEditOutcome> rename({
    required String path,
    required String newName,
  }) async {
    return _invokeEdit('renameDeviceMedia', {
      'path': path,
      'newName': newName,
    });
  }

  /// Deletes one or more files from the user's media library.
  ///
  /// Passing every path in a single call matters: Android shows one consent
  /// dialog for the batch instead of one per file.
  Future<DeviceMediaEditOutcome> delete(
    List<String> paths,
  ) async {
    if (paths.isEmpty) {
      return (result: DeviceMediaEditResult.success, message: null);
    }
    return _invokeEdit('deleteDeviceMedia', {'paths': paths});
  }

  /// Moves files into [targetFolder].
  ///
  /// Native side copies then deletes, so a failure mid-move leaves the
  /// original where it was rather than losing it.
  Future<DeviceMediaEditOutcome> move({
    required List<String> paths,
    required String targetFolder,
  }) async {
    if (paths.isEmpty) {
      return (result: DeviceMediaEditResult.success, message: null);
    }
    return _invokeEdit('moveDeviceMedia', {
      'paths': paths,
      'targetFolder': targetFolder,
    });
  }

  /// Updates the title / artist / album the media library holds for a file.
  ///
  /// Pass null for a field to leave it untouched.
  Future<DeviceMediaEditOutcome> updateTags({
    required String path,
    String? title,
    String? artist,
    String? album,
  }) async {
    return _invokeEdit('updateDeviceMediaTags', {
      'path': path,
      'title': title,
      'artist': artist,
      'album': album,
    });
  }

  /// Asks once for permission to modify a whole set of files.
  ///
  /// Android has no runtime permission for "modify my media" — READ_MEDIA_*
  /// grants reading and nothing more, and the only blanket alternative,
  /// MANAGE_EXTERNAL_STORAGE, is restricted by Play to file managers and
  /// backup tools. What the platform does allow is asking about many files at
  /// once: one dialog for the whole library instead of one per rename.
  ///
  /// Best-effort by design. A refusal is not an error — the per-edit consent
  /// path still works, it just asks again — so the caller gets a plain bool
  /// and nothing downstream depends on it.
  Future<bool> requestWriteAccess(List<String> paths) async {
    if (!_hasMediaStore || paths.isEmpty) return false;
    try {
      final granted = await _channel
          .invokeMethod<bool>('requestMediaWriteAccess', {'paths': paths})
          .timeout(_consentTimeout);
      return granted ?? false;
    } on TimeoutException {
      debugPrint('requestMediaWriteAccess timed out');
      return false;
    } on PlatformException catch (error) {
      debugPrint('requestMediaWriteAccess failed: ${error.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<DeviceMediaEditOutcome> _invokeEdit(
    String method,
    Map<String, Object?> arguments,
  ) async {
    if (!_hasMediaStore) {
      return (
        result: DeviceMediaEditResult.failed,
        message: 'Editing device files is only supported on Android.',
      );
    }
    try {
      final granted = await _channel
          .invokeMethod<bool>(method, arguments)
          .timeout(_consentTimeout);
      // Any successful edit makes the cached library stale — the browser would
      // otherwise redraw from a snapshot that still lists the old name.
      if (granted == true) invalidate();
      return granted == true
          ? (result: DeviceMediaEditResult.success, message: null)
          : (result: DeviceMediaEditResult.declined, message: null);
    } on TimeoutException {
      debugPrint('DeviceMediaService.$method timed out waiting for consent');
      return (
        result: DeviceMediaEditResult.failed,
        message: 'Timed out waiting for permission. Please try again.',
      );
    } on PlatformException catch (error) {
      debugPrint('DeviceMediaService.$method failed: ${error.message}');
      return (result: DeviceMediaEditResult.failed, message: error.message);
    } on MissingPluginException {
      // Older install that predates the native handler.
      return (
        result: DeviceMediaEditResult.failed,
        message: 'This build cannot edit device files.',
      );
    }
  }


  static const Set<String> videoExtensions = {'mp4', 'mkv', 'webm', 'avi', 'mov', 'flv', '3gp', 'm4v'};
  static const Set<String> audioExtensions = {'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'opus', 'wma'};
  static const Set<String> imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic'};

  /// MediaStore's own MEDIA_TYPE values, passed through verbatim from Kotlin.
  ///
  /// These are Android's numbers, not ours: `MediaStore.Files.FileColumns`
  /// defines IMAGE = 1, AUDIO = 2, VIDEO = 3. Audio and video were swapped
  /// here, which meant `foldersFor(video)` asked the library for audio — the
  /// Videos tab listed music folders, the Audio tab listed video folders, and
  /// a folder holding both showed the wrong half of itself in each place.
  static const _mediaTypeImage = 1;
  static const _mediaTypeAudio = 2;
  static const _mediaTypeVideo = 3;

  /// Cached library, keyed by nothing but recency.
  ///
  /// All three folder lists come from a single query. The old code ran one
  /// full recursive filesystem walk per media type — three passes over the
  /// user's entire storage to build three lists from the same data.
  List<DeviceMediaEntry>? _cache;
  DateTime? _cachedAt;

  /// Only long enough to collapse the three per-type reads that make up one
  /// refresh into a single query. Deciding when a listing is stale is the
  /// caller's job, not this cache's.
  static const _cacheTtl = Duration(seconds: 30);

  /// Reads the whole media library.
  ///
  /// Returns an empty list rather than throwing: a browser with no rows is a
  /// recoverable state the UI already handles, an exception during a refresh
  /// is not.
  Future<List<DeviceMediaEntry>> loadLibrary({bool force = false}) async {
    final cached = _cache;
    final cachedAt = _cachedAt;
    if (!force &&
        cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _cacheTtl) {
      return cached;
    }

    if (!_hasMediaStore) {
      return _remember(await _scanFilesystem());
    }

    try {
      final rows = await _channel.invokeListMethod<Object?>('queryDeviceMedia');
      final entries = <DeviceMediaEntry>[];
      for (final row in rows ?? const []) {
        if (row is! Map) continue;
        final entry = DeviceMediaEntry.fromNative(row);
        if (entry != null) entries.add(entry);
      }
      return _remember(entries);
    } on PlatformException catch (error) {
      debugPrint('queryDeviceMedia failed: ${error.message}');
    } on MissingPluginException {
      debugPrint('queryDeviceMedia unavailable — falling back to a scan');
    }

    // MediaStore is the right answer on every supported Android release, but
    // an unindexed sideloaded file or a failed query should still show
    // something rather than an empty library.
    return _remember(await _scanFilesystem());
  }

  /// Filters out Duck's own files, then caches.
  ///
  /// Applied here rather than at each call site so that every path into the
  /// library — MediaStore, the fallback scan, the move-destination picker —
  /// gets the same treatment. A vault filename leaking into any one of them
  /// would defeat the vault.
  List<DeviceMediaEntry> _remember(List<DeviceMediaEntry> entries) {
    final visible = [
      for (final entry in entries)
        if (!_isAppPrivate(entry.path)) entry,
    ];
    _cache = visible;
    _cachedAt = DateTime.now();
    return visible;
  }

  /// Drops the cache so the next read hits storage.
  void invalidate() {
    _cache = null;
    _cachedAt = null;
  }

  /// Path fragments that belong to Duck's own machinery, not to the user.
  ///
  /// The browser lists the user's media library. Duck's working files are not
  /// part of it: the encrypted vault, the plaintext copy the player decrypts
  /// to while a vault item is open, the silent track the background-audio
  /// handoff loads, intruder snapshots, and the outputs of convert/compress
  /// before the user has saved them anywhere. Showing those is confusing at
  /// best — and for the vault, a privacy leak, since it exposes filenames the
  /// vault exists to hide.
  static const _privateFragments = <String>[
    '/Duck Downloader/.Vault',
    '/Duck Downloader/Ringtones',
    '/duck-downloads',
    '/duck-vault-temp',
    '/Android/data/com.duck.downloader',
    '/cache/',
    '/.thumbnails/',
    '/.trashed',
  ];

  /// True when a path is Duck's own rather than the user's.
  static bool _isAppPrivate(String path) {
    for (final fragment in _privateFragments) {
      if (path.contains(fragment)) return true;
    }
    return false;
  }

  /// Groups the library into folders for one media type.
  Future<List<DeviceMediaFolder>> foldersFor(
    DownloadType type, {
    bool force = false,
  }) async {
    final entries = await loadLibrary(force: force);
    final wanted = switch (type) {
      DownloadType.video => _mediaTypeVideo,
      DownloadType.audio => _mediaTypeAudio,
      DownloadType.image => _mediaTypeImage,
    };

    final buckets = <String, List<DeviceMediaEntry>>{};
    final names = <String, String>{};
    for (final entry in entries) {
      if (entry.mediaType != wanted) continue;
      buckets.putIfAbsent(entry.folderPath, () => []).add(entry);
      names[entry.folderPath] = entry.folderName;
    }

    final folders = <DeviceMediaFolder>[];
    buckets.forEach((path, items) {
      // Already newest-first from the query, so the cover is the most recent
      // file rather than whichever one happened to be enumerated first.
      folders.add(
        DeviceMediaFolder(
          name: names[path] ?? p.basename(path),
          path: path,
          itemCount: items.length,
          coverPath: items.first.path,
          items: [for (final item in items) item.toDownloadItem(type)],
          entries: items,
          totalBytes: items.fold<int>(0, (sum, item) => sum + item.size),
          type: type,
        ),
      );
    });

    folders.sort((a, b) => b.itemCount.compareTo(a.itemCount));
    return folders;
  }

  /// Re-reads one folder straight from the library.
  ///
  /// Every edit path uses this instead of patching the list it already has.
  /// Guessing the result of a rename or a move is what made file management
  /// feel broken: Android is free to uniquify a clashing name, to land a moved
  /// file on a different volume, or to reject the change after the app has
  /// already redrawn as though it went through. The library is the only
  /// account of what actually happened, so ask it.
  ///
  /// Returns null once the folder holds nothing of [type] any more — moving
  /// the last video out of a folder full of photos is an ordinary way to get
  /// here, not an error.
  Future<DeviceMediaFolder?> refreshFolder(
    String path,
    DownloadType type,
  ) async {
    final folders = await foldersFor(type, force: true);
    for (final folder in folders) {
      if (folder.path == path) return folder;
    }
    return null;
  }

  Future<List<DeviceMediaFolder>> getVideoFolders(
    List<DownloadItem> downloads, {
    bool force = false,
  }) => foldersFor(DownloadType.video, force: force);

  Future<List<DeviceMediaFolder>> getImageFolders(
    List<DownloadItem> downloads, {
    bool force = false,
  }) => foldersFor(DownloadType.image, force: force);

  Future<List<DeviceMediaFolder>> getAudioFolders(
    List<DownloadItem> downloads, {
    bool force = false,
  }) => foldersFor(DownloadType.audio, force: force);

  /// Paths in the library, newest first.
  ///
  /// Feeds the one-time bulk consent request, which is capped on the native
  /// side — so ordering matters: whatever is cut is the least likely to be
  /// what the user reaches for next.
  Future<List<String>> libraryPaths({int limit = 500}) async {
    final entries = await loadLibrary();
    return [for (final entry in entries.take(limit)) entry.path];
  }

  /// Candidate destination folders for a move.
  Future<List<DeviceMediaFolder>> destinationFolders() async {
    final entries = await loadLibrary();
    final buckets = <String, List<DeviceMediaEntry>>{};
    final names = <String, String>{};
    for (final entry in entries) {
      buckets.putIfAbsent(entry.folderPath, () => []).add(entry);
      names[entry.folderPath] = entry.folderName;
    }
    final folders = [
      for (final path in buckets.keys)
        DeviceMediaFolder(
          name: names[path] ?? p.basename(path),
          path: path,
          itemCount: buckets[path]!.length,
          coverPath: buckets[path]!.first.path,
          items: const [],
          entries: buckets[path]!,
          totalBytes: 0,
        ),
    ];
    folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return folders;
  }

  // ── Fallback scan ─────────────────────────────────────────────────────────

  /// Last-resort filesystem walk, used only when MediaStore is unavailable.
  ///
  /// Runs on a background isolate: `listSync` blocks, and blocking the root
  /// isolate is what froze the UI for seconds on every launch.
  Future<List<DeviceMediaEntry>> _scanFilesystem() async {
    final roots = await _scanRoots();
    if (roots.isEmpty) return const [];
    try {
      return await Isolate.run(() => _walk(roots));
    } catch (error) {
      debugPrint('Fallback media scan failed: $error');
      return const [];
    }
  }

  Future<List<String>> _scanRoots() async {
    final roots = <String>[];
    try {
      if (!Platform.isAndroid) {
        final docs = await getApplicationDocumentsDirectory();
        roots.add(docs.path);
        return roots;
      }
      // Every mounted volume, so SD cards are covered rather than only the
      // hardcoded internal-storage folder list the old scan used.
      final storage = Directory('/storage');
      if (storage.existsSync()) {
        for (final entity in storage.listSync()) {
          if (entity is! Directory) continue;
          final name = p.basename(entity.path);
          if (name == 'self' || name == 'emulated') continue;
          roots.add(entity.path);
        }
      }
      final primary = Directory('/storage/emulated/0');
      if (primary.existsSync()) roots.add(primary.path);
    } catch (error) {
      debugPrint('Could not enumerate storage volumes: $error');
    }
    return roots;
  }

  /// Runs inside an isolate — must stay a top-level-callable pure function.
  static List<DeviceMediaEntry> _walk(List<String> roots) {
    const skip = {'Android', '.thumbnails', '.trashed', 'cache', '.cache'};
    final extensions = <String, int>{
      for (final ext in imageExtensions) ext: _mediaTypeImage,
      for (final ext in videoExtensions) ext: _mediaTypeVideo,
      for (final ext in audioExtensions) ext: _mediaTypeAudio,
    };

    final entries = <DeviceMediaEntry>[];
    final seen = <String>{};

    void visit(Directory dir, int depth) {
      if (depth > 6) return;
      List<FileSystemEntity> children;
      try {
        children = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final child in children) {
        final name = p.basename(child.path);
        if (name.startsWith('.') && child is Directory) continue;
        if (child is Directory) {
          if (skip.contains(name)) continue;
          visit(child, depth + 1);
          continue;
        }
        if (child is! File) continue;
        final ext = p.extension(child.path).replaceFirst('.', '').toLowerCase();
        final type = extensions[ext];
        if (type == null) continue;
        if (!seen.add(child.path)) continue;
        try {
          final stat = child.statSync();
          entries.add(
            DeviceMediaEntry(
              id: child.path,
              name: name,
              path: child.path,
              folderPath: child.parent.path,
              folderName: p.basename(child.parent.path),
              size: stat.size,
              mimeType: null,
              modified: stat.modified,
              mediaType: type,
              duration: null,
            ),
          );
        } catch (_) {
          // Unreadable file — skip rather than abort the whole scan.
        }
      }
    }

    for (final root in roots) {
      visit(Directory(root), 0);
    }
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  }
}
