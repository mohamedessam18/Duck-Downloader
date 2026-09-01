import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../models/download_models.dart';

class ExternalSaveResult {
  const ExternalSaveResult({required this.success, this.uri});

  final bool success;
  final String? uri;
}

class MediaSaveService {
  MediaSaveService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('duck_downloader/media');

  final MethodChannel _channel;

  Future<ExternalSaveResult> saveVideo({
    required String path,
    required String filename,
  }) {
    return _invokeSave(
      method: 'saveVideo',
      path: path,
      filename: filename,
      mimeType: 'video/mp4',
    );
  }

  /// iOS has no writable Music library for third-party apps, so audio is handed
  /// to the system share sheet ("Save to Files" / "Copy to …") instead.
  ///
  /// [interactive] must be false for automatic post-download saving: popping a
  /// share sheet the user never asked for is jarring, so on iOS the call becomes
  /// a no-op and reports failure rather than hijacking the screen.
  Future<ExternalSaveResult> saveAudio({
    required String path,
    required String filename,
    required DownloadType type,
    bool interactive = true,
  }) async {
    if (Platform.isIOS) {
      if (!interactive) return const ExternalSaveResult(success: false);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], subject: filename),
      );
      return const ExternalSaveResult(success: true);
    }
    return _invokeSave(
      method: 'saveAudioToMusic',
      path: path,
      filename: filename,
      mimeType: filename.toLowerCase().endsWith('.m4a')
          ? 'audio/mp4'
          : 'audio/mpeg',
    );
  }

  Future<ExternalSaveResult> saveImage({
    required String path,
    required String filename,
    required String mimeType,
  }) {
    // Both platforms save straight into the system gallery (Photos /
    // MediaStore). The iOS side is implemented in AppDelegate.swift.
    return _invokeSave(
      method: 'saveImage',
      path: path,
      filename: filename,
      mimeType: mimeType,
    );
  }

  Future<ExternalSaveResult> _invokeSave({
    required String method,
    required String path,
    required String filename,
    required String mimeType,
  }) async {
    final ext = p.extension(filename);
    var base = p.basenameWithoutExtension(filename);
    if (base.length > 60) {
      base = base.substring(0, 60).trim();
    }
    final safeFilename = '$base$ext';

    final result = await _channel.invokeMapMethod<String, Object?>(method, {
      'path': path,
      'filename': safeFilename,
      'mimeType': mimeType,
    });
    return ExternalSaveResult(
      success: result?['success'] == true,
      uri: result?['uri']?.toString(),
    );
  }
}
