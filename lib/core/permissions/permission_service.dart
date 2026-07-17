import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  Future<bool> requestStoragePermission() async {
    if (Platform.isIOS) return true;
    final status = await Permission.storage.request();
    return status.isGranted;
  }

  Future<bool> requestMediaImagesPermission() async {
    if (Platform.isIOS) {
      final status = await Permission.photos.request();
      return status.isGranted;
    }
    final photosStatus = await Permission.photos.request();
    if (photosStatus.isGranted) return true;
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
      final photosStatus = await Permission.photos.request();
      if (!photosStatus.isGranted) {
        await Permission.storage.request();
      }
    }
  }

  Future<bool> hasStoragePermission() async {
    if (Platform.isIOS) return true;
    final storageGranted = await Permission.storage.isGranted;
    final photosGranted = await Permission.photos.isGranted;
    return storageGranted || photosGranted;
  }

  Future<bool> hasMediaImagesPermission() async {
    if (Platform.isIOS) {
      return await Permission.photos.isGranted;
    }
    final photosGranted = await Permission.photos.isGranted;
    final storageGranted = await Permission.storage.isGranted;
    return photosGranted || storageGranted;
  }
}
