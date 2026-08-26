import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  Future<bool> requestStoragePermission() async {
    if (Platform.isIOS) return true;
    final photos = await Permission.photos.request();
    final videos = await Permission.videos.request();
    final audio = await Permission.audio.request();
    final storage = await Permission.storage.request();
    return photos.isGranted || videos.isGranted || audio.isGranted || storage.isGranted;
  }

  Future<bool> requestMediaImagesPermission() async {
    if (Platform.isIOS) {
      final status = await Permission.photos.request();
      return status.isGranted;
    }
    final photosStatus = await Permission.photos.request();
    final videosStatus = await Permission.videos.request();
    final audioStatus = await Permission.audio.request();
    if (photosStatus.isGranted || videosStatus.isGranted || audioStatus.isGranted) return true;
    final storageStatus = await Permission.storage.request();
    return storageStatus.isGranted;
  }

  Future<bool> requestNotificationPermission() async {
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  Future<void> requestAllRequiredPermissions() async {
    await Permission.notification.request();
    if (Platform.isIOS) {
      await Permission.photos.request();
    } else {
      await Permission.photos.request();
      await Permission.videos.request();
      await Permission.audio.request();
      await Permission.storage.request();
    }
  }

  Future<bool> hasStoragePermission() async {
    if (Platform.isIOS) return true;
    final storageGranted = await Permission.storage.isGranted;
    final photosGranted = await Permission.photos.isGranted;
    final videosGranted = await Permission.videos.isGranted;
    final audioGranted = await Permission.audio.isGranted;
    return storageGranted || photosGranted || videosGranted || audioGranted;
  }

  Future<bool> hasMediaImagesPermission() => hasStoragePermission();

  /// Requests everything the media folders browser needs to list the user's
  /// own images, video and audio.
  ///
  /// Android 13 replaced READ_EXTERNAL_STORAGE with one permission per media
  /// type, and Android 14 added a "selected photos only" answer that reports
  /// as `limited` rather than granted. Treating `limited` as a denial made the
  /// browser look empty for anyone who picked it, with no way to recover from
  /// inside the app.
  Future<bool> requestMediaLibraryAccess() async {
    if (Platform.isIOS) {
      final status = await Permission.photos.request();
      return status.isGranted || status.isLimited;
    }

    final results = await [
      Permission.photos,
      Permission.videos,
      Permission.audio,
    ].request();

    final anyGranted = results.values.any(
      (status) => status.isGranted || status.isLimited,
    );
    if (anyGranted) return true;

    // Android 12 and below: the split permissions do not exist, so the request
    // above resolves to the legacy one instead.
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  /// True when at least one media type is readable.
  ///
  /// Partial ("selected photos") access counts: the browser shows what the
  /// user chose to share rather than nothing at all.
  Future<bool> hasMediaLibraryAccess() async {
    if (Platform.isIOS) {
      final status = await Permission.photos.status;
      return status.isGranted || status.isLimited;
    }
    for (final permission in [
      Permission.photos,
      Permission.videos,
      Permission.audio,
      Permission.storage,
    ]) {
      final status = await permission.status;
      if (status.isGranted || status.isLimited) return true;
    }
    return false;
  }
}
