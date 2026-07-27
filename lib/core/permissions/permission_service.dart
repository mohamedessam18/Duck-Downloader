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
}
