import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// How hard to squeeze.
///
/// The numbers are CRF values for H.264: lower is better quality and a bigger
/// file. 23 is ffmpeg's default and visually transparent for most content, so
/// [CompressLevel.light] barely shrinks anything — the useful range is 26-32.
enum CompressLevel {
  light(crf: 26, scale: null, audioBitrate: 128, label: 'Light'),
  balanced(crf: 28, scale: 1280, audioBitrate: 128, label: 'Balanced'),
  strong(crf: 32, scale: 854, audioBitrate: 96, label: 'Strong');

  const CompressLevel({
    required this.crf,
    required this.scale,
    required this.audioBitrate,
    required this.label,
  });

  final int crf;

  /// Longest-edge cap in pixels, or null to keep the original size.
  final int? scale;
  final int audioBitrate;
  final String label;
}

class CompressResult {
  const CompressResult({
    required this.outputPath,
    required this.originalBytes,
    required this.compressedBytes,
  });

  final String outputPath;
  final int originalBytes;
  final int compressedBytes;

  /// 0.0 – 1.0. Negative would mean it grew, which [CompressService] rejects.
  double get savedFraction {
    if (originalBytes <= 0) return 0;
    return (originalBytes - compressedBytes) / originalBytes;
  }
}

/// Re-encodes video and audio to a smaller file.
class CompressService {
  const CompressService._();

  /// Compresses [inputPath], reporting 0.0-1.0 progress.
  ///
  /// Writes to a new file next to the app's other output rather than editing
  /// in place: a re-encode is lossy and cannot be undone, so the original has
  /// to survive until the user decides otherwise.
  static Future<CompressResult> compressVideo({
    required String inputPath,
    CompressLevel level = CompressLevel.balanced,
    void Function(double progress)? onProgress,
  }) async {
    final input = File(inputPath);
    if (!await input.exists()) {
      throw Exception('That file no longer exists.');
    }
    final originalBytes = await input.length();
    final outputPath = await _outputPathFor(inputPath, 'compressed', 'mp4');

    final durationMs = await _durationMsOf(inputPath);
    final filters = level.scale == null
        ? <String>[]
        // -2 keeps the other axis even, which H.264 requires; scaling only
        // when the source is larger avoids upscaling a small clip.
        : ['-vf', "scale='min(${level.scale},iw)':-2"];

    final args = <String>[
      '-y',
      '-i', inputPath,
      '-c:v', 'libx264',
      '-preset', 'veryfast',
      '-crf', '${level.crf}',
      ...filters,
      '-c:a', 'aac',
      '-b:a', '${level.audioBitrate}k',
      // Lets a player start before the whole file has downloaded, and costs
      // nothing to set here.
      '-movflags', '+faststart',
      outputPath,
    ];

    await _run(args, durationMs: durationMs, onProgress: onProgress);

    final output = File(outputPath);
    if (!await output.exists()) {
      throw Exception('Compression produced no file.');
    }
    final compressedBytes = await output.length();

    // Re-encoding an already-efficient file routinely makes it bigger. Keeping
    // that result would be strictly worse than doing nothing, and the user
    // asked to save space.
    if (compressedBytes >= originalBytes) {
      await output.delete();
      throw Exception(
        'This file is already well compressed — a smaller version was not '
        'possible without losing noticeable quality.',
      );
    }

    return CompressResult(
      outputPath: outputPath,
      originalBytes: originalBytes,
      compressedBytes: compressedBytes,
    );
  }

  static Future<CompressResult> compressAudio({
    required String inputPath,
    int bitrate = 128,
    void Function(double progress)? onProgress,
  }) async {
    final input = File(inputPath);
    if (!await input.exists()) {
      throw Exception('That file no longer exists.');
    }
    final originalBytes = await input.length();
    final outputPath = await _outputPathFor(inputPath, 'compressed', 'm4a');
    final durationMs = await _durationMsOf(inputPath);

    await _run(
      ['-y', '-i', inputPath, '-vn', '-c:a', 'aac', '-b:a', '${bitrate}k', outputPath],
      durationMs: durationMs,
      onProgress: onProgress,
    );

    final output = File(outputPath);
    if (!await output.exists()) {
      throw Exception('Compression produced no file.');
    }
    final compressedBytes = await output.length();
    if (compressedBytes >= originalBytes) {
      await output.delete();
      throw Exception('This file is already at or below that bitrate.');
    }
    return CompressResult(
      outputPath: outputPath,
      originalBytes: originalBytes,
      compressedBytes: compressedBytes,
    );
  }

  static Future<void> _run(
    List<String> args, {
    required int? durationMs,
    void Function(double progress)? onProgress,
  }) async {
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      null,
      null,
      (Statistics stats) {
        if (onProgress == null || durationMs == null || durationMs <= 0) return;
        final done = stats.getTime() / durationMs;
        onProgress(done.clamp(0.0, 1.0));
      },
    );

    // executeWithArgumentsAsync returns as soon as the session starts, so wait
    // for the real outcome rather than reporting success immediately.
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      debugPrint('Compression failed: $logs');
      throw Exception('Could not compress that file.');
    }
    onProgress?.call(1);
  }

  /// Total duration in milliseconds, used only to turn ffmpeg's elapsed-time
  /// statistics into a progress fraction.
  static Future<int?> _durationMsOf(String path) async {
    try {
      final session = await FFmpegKit.execute('-i "$path" -f null -');
      final logs = await session.getAllLogsAsString() ?? '';
      final match =
          RegExp(r'Duration: (\d+):(\d+):(\d+)\.(\d+)').firstMatch(logs);
      if (match == null) return null;
      return Duration(
        hours: int.parse(match.group(1)!),
        minutes: int.parse(match.group(2)!),
        seconds: int.parse(match.group(3)!),
        milliseconds: int.parse(match.group(4)!) * 10,
      ).inMilliseconds;
    } catch (_) {
      // Progress becomes indeterminate; the job still runs.
      return null;
    }
  }

  static Future<String> _outputPathFor(
    String inputPath,
    String suffix,
    String extension,
  ) async {
    final root = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(root.path, 'Duck Downloader', 'Compressed'));
    await folder.create(recursive: true);

    final base = p.basenameWithoutExtension(inputPath);
    var candidate = p.join(folder.path, '${base}_$suffix.$extension');
    var counter = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(folder.path, '${base}_${suffix}_$counter.$extension');
      counter++;
    }
    return candidate;
  }
}
