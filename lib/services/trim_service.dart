import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/download_models.dart';

class TrimValidationException implements Exception {
  TrimValidationException(this.message);
  final String message;

  @override
  String toString() => message;
}

class TrimService {
  static const minClipSeconds = 1.0;

  static void validateRange({
    required double startSec,
    required double endSec,
    required Duration totalDuration,
  }) {
    if (kIsWeb) {
      throw TrimValidationException('Trim is not supported on web.');
    }
    if (totalDuration <= Duration.zero) {
      throw TrimValidationException('Media duration is not available yet.');
    }
    if (startSec < 0 || endSec <= startSec) {
      throw TrimValidationException('Invalid trim range.');
    }
    if (endSec - startSec < minClipSeconds) {
      throw TrimValidationException('Clip must be at least 1 second long.');
    }
    if (endSec > totalDuration.inSeconds + 0.5) {
      throw TrimValidationException('Trim end exceeds media duration.');
    }
  }

  Future<String> trimLocalFile({
    required String inputPath,
    required double startSec,
    required double endSec,
    required DownloadType type,
  }) async {
    if (kIsWeb) {
      throw TrimValidationException('Trim is not supported on web.');
    }

    final input = File(inputPath);
    if (!await input.exists()) {
      throw TrimValidationException('Source file is not available.');
    }

    final ext = p.extension(inputPath).isEmpty
        ? (type == DownloadType.audio ? '.mp3' : '.mp4')
        : p.extension(inputPath);
    final dir = p.dirname(inputPath);
    final tempPath = p.join(
      dir,
      'trimmed_${DateTime.now().millisecondsSinceEpoch}$ext',
    );

    final copyArgs = [
      '-y',
      '-ss',
      startSec.toStringAsFixed(3),
      '-to',
      endSec.toStringAsFixed(3),
      '-i',
      inputPath,
      '-c',
      'copy',
      tempPath,
    ];

    var session = await FFmpegKit.executeWithArguments(copyArgs);
    var returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) {
      final reencodeArgs = [
        '-y',
        '-ss',
        startSec.toStringAsFixed(3),
        '-to',
        endSec.toStringAsFixed(3),
        '-i',
        inputPath,
        tempPath,
      ];
      session = await FFmpegKit.executeWithArguments(reencodeArgs);
      returnCode = await session.getReturnCode();
    }

    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      if (File(tempPath).existsSync()) {
        await File(tempPath).delete();
      }
      throw TrimValidationException(
        logs?.trim().isNotEmpty == true
            ? 'FFmpeg failed: ${logs!.trim()}'
            : 'Could not trim this file.',
      );
    }

    final output = File(tempPath);
    if (!await output.exists() || await output.length() <= 0) {
      throw TrimValidationException('Trim produced an empty file.');
    }

    return tempPath;
  }

  Future<String> replaceOriginal({
    required String originalPath,
    required String trimmedPath,
  }) async {
    final original = File(originalPath);
    final trimmed = File(trimmedPath);
    if (!await trimmed.exists()) {
      throw TrimValidationException('Trimmed file missing.');
    }

    if (await original.exists()) {
      await original.delete();
    }
    await trimmed.rename(originalPath);
    return originalPath;
  }
}
