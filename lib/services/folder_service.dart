import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/download_models.dart';

/// Folders the user makes, holding files that really move.
///
/// The Folders tab lists what is already on the phone; this is the other kind
/// — somewhere to put things, rather than a report of where they landed.
///
/// They live inside the media collections the phone already shows, beside the
/// downloads Duck saves there: `Movies/Duck Downloader/<folder>` and its
/// siblings for music and pictures. The first version put them in the app's
/// private directory, which produced a "real folder" only the app that made it
/// could see — not what anybody means by the word, and the first thing anyone
/// noticed.
///
/// A folder is a name the user chose. The directory behind it is created by
/// the media store when the first file goes in, so nothing here enumerates
/// shared storage or asks for a permission to do it.
class FolderService {
  const FolderService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('duck_downloader/media');

  final MethodChannel _channel;

  /// Characters a folder name may not carry, because a path cannot.
  static final _illegal = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

  /// A name that can be a directory, or null when nothing usable is left.
  static String? sanitiseName(String raw) {
    final cleaned = raw
        .replaceAll(_illegal, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        // A leading dot hides the folder from the file browsers the user might
        // open it in, which is the opposite of the point.
        .replaceAll(RegExp(r'^\.+'), '')
        .trim();
    if (cleaned.isEmpty) return null;
    return cleaned.length <= 60 ? cleaned : cleaned.substring(0, 60).trim();
  }

  static String _mimeFor(DownloadItem item) => switch (item.type) {
    DownloadType.audio => 'audio/mpeg',
    DownloadType.image => 'image/jpeg',
    DownloadType.video => 'video/mp4',
  };

  static String _kindFor(DownloadItem item) => switch (item.type) {
    DownloadType.audio => 'audio',
    DownloadType.image => 'image',
    DownloadType.video => 'video',
  };

  /// Files [item] under [folder], or back out to the plain download folder
  /// when [folder] is null.
  ///
  /// Returns where the file now lives, or null when nothing moved. The file is
  /// moved, not copied: one file, in one place, which is the only way the
  /// storage screen can tell the truth.
  Future<String?> move(DownloadItem item, {required String? folder}) async {
    final path = item.filePath;
    if (path == null) return null;

    // Never. A vault file is encrypted precisely so its name does not appear
    // anywhere outside the app, and these folders are visible in the phone's
    // own file manager. This is checked here as well as in the UI because the
    // UI is where the rule is easy to forget.
    if (item.isPrivate) return null;

    final name = folder == null ? null : sanitiseName(folder);
    if (folder != null && name == null) return null;

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'moveIntoFolder',
        {
          'path': path,
          'filename': p.basename(path),
          'mimeType': _mimeFor(item),
          'kind': _kindFor(item),
          'folder': name,
        },
      );
      final moved = result?['path'] as String?;
      return (moved == null || moved.isEmpty) ? null : moved;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // Every platform but Android, and the tests. Nothing moves rather than
      // something breaking.
      return null;
    }
  }
}
