import 'dart:io';

import 'package:flutter/services.dart';
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

  Future<ExternalSaveResult> saveAudio({
    required String path,
    required String filename,
    required DownloadType type,
  }) async {
    if (Platform.isIOS) {
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
  }) async {
    if (Platform.isIOS) {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], subject: filename),
      );
      return const ExternalSaveResult(success: true);
    }
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
    final result = await _channel.invokeMapMethod<String, Object?>(method, {
      'path': path,
      'filename': filename,
      'mimeType': mimeType,
    });
    return ExternalSaveResult(
      success: result?['success'] == true,
      uri: result?['uri']?.toString(),
    );
  }
}
