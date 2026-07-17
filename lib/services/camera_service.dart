import 'dart:io';
import 'package:camera/camera.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class VaultCameraService {
  static const String _intrudersDirName = '.Intruders';

  /// Captures a silent photo using the front camera and saves it in a hidden folder
  static Future<void> captureIntruderSelfie() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      // Find the front-facing camera
      CameraDescription? frontCamera;
      for (final camera in cameras) {
        if (camera.lensDirection == CameraLensDirection.front) {
          frontCamera = camera;
          break;
        }
      }

      // Fallback to first camera if front camera is not found
      frontCamera ??= cameras.first;

      final controller = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await controller.initialize();
      final XFile imageFile = await controller.takePicture();
      await controller.dispose();

      // Save the picture to the hidden intruders folder
      final root = await getApplicationDocumentsDirectory();
      final intrudersFolder = Directory(
        p.join(root.path, 'Duck Downloader', '.Vault', _intrudersDirName),
      );
      await intrudersFolder.create(recursive: true);

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final destPath = p.join(intrudersFolder.path, 'intruder_$timestamp.jpg');

      final savedFile = File(imageFile.path);
      if (await savedFile.exists()) {
        await savedFile.copy(destPath);
        await savedFile.delete(); // Clean up temporary cache file
      }
    } catch (_) {
      // Fail silently to prevent crashing the UI when camera permissions are denied or camera is in use
    }
  }

  /// Retrieves list of all logged intruder selfie images
  static Future<List<File>> getIntruderLogs() async {
    try {
      final root = await getApplicationDocumentsDirectory();
      final intrudersFolder = Directory(
        p.join(root.path, 'Duck Downloader', '.Vault', _intrudersDirName),
      );
      if (!await intrudersFolder.exists()) return [];

      final files = intrudersFolder
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('intruder_') && p.basename(f.path).endsWith('.jpg'))
          .toList();

      // Sort files by timestamp (newest first)
      files.sort((a, b) => b.path.compareTo(a.path));
      return files;
    } catch (_) {
      return [];
    }
  }

  /// Clears all logged intruder selfie images
  static Future<void> clearIntruderLogs() async {
    try {
      final root = await getApplicationDocumentsDirectory();
      final intrudersFolder = Directory(
        p.join(root.path, 'Duck Downloader', '.Vault', _intrudersDirName),
      );
      if (await intrudersFolder.exists()) {
        await intrudersFolder.delete(recursive: true);
      }
    } catch (_) {}
  }
}
