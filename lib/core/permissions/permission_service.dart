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
    final status = await Permission.storage.request();
    return status.isGranted;
  }

  Future<bool> requestNotificationPermission() async {
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  Future<void> requestAllRequiredPermissions() async {
    // 1. Request Notification permission
    await Permission.notification.request();

    // 2. Request Storage / Photo Library permissions
    if (Platform.isIOS) {
      await Permission.photos.request();
    } else {
      await Permission.storage.request();
    }
  }

  Future<bool> hasStoragePermission() async {
    if (Platform.isIOS) return true;
    return await Permission.storage.isGranted;
  }

  Future<bool> hasMediaImagesPermission() async {
    if (Platform.isIOS) {
      return await Permission.photos.isGranted;
    }
    return await Permission.storage.isGranted;
  }
}
