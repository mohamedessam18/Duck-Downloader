import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ConversionService {
  /// Converts a video file to audio (MP3/M4A) at a given bitrate (in kbps)
  static Future<String> convertVideoToAudio({
    required String inputPath,
    required String format, // 'mp3' or 'm4a'
    required int bitrate,   // 128, 192, 320
  }) async {
    final inputFile = File(inputPath);
    if (!await inputFile.exists()) {
      throw Exception('Input video file does not exist at $inputPath');
    }

    final root = await getApplicationDocumentsDirectory();
    final audiosFolder = Directory(p.join(root.path, 'Duck Downloader', 'Audios'));
    await audiosFolder.create(recursive: true);

    var inputBasename = p.basenameWithoutExtension(inputPath);
    if (inputBasename.length > 60) {
      inputBasename = inputBasename.substring(0, 60).trim();
    }
    final outputFilename = '${inputBasename}_extracted.$format';
    final outputPath = p.join(audiosFolder.path, outputFilename);

    // If the file already exists, generate a unique filename
    var finalOutputPath = outputPath;
    var counter = 1;
    while (await File(finalOutputPath).exists()) {
      finalOutputPath = p.join(audiosFolder.path, '${inputBasename}_extracted_$counter.$format');
      counter++;
    }

    // FFmpeg commands:
    // MP3: -vn (no video) -acodec libmp3lame -ab {bitrate}k
    // M4A: -vn (no video) -c:a aac -b:a {bitrate}k
    final List<String> args = [];
    args.addAll(['-y', '-i', inputPath, '-vn']);
    if (format == 'mp3') {
      args.addAll(['-acodec', 'libmp3lame', '-ab', '${bitrate}k']);
    } else {
      args.addAll(['-c:a', 'aac', '-b:a', '${bitrate}k']);
    }
    args.add(finalOutputPath);

    final session = await FFmpegKit.executeWithArguments(args);
    final returnCode = await session.getReturnCode();

    if (ReturnCode.isSuccess(returnCode)) {
      final outputFile = File(finalOutputPath);
      if (await outputFile.exists() && await outputFile.length() > 0) {
        return finalOutputPath;
      } else {
        throw Exception('Converted audio file is empty.');
      }
    } else {
      final logs = await session.getAllLogsAsString();
      throw Exception('FFmpeg conversion failed: ${logs?.trim() ?? 'unknown error'}');
    }
  }

  /// Creates a GIF file from a video segment
  static Future<String> createGifFromVideo({
    required String inputPath,
    required double startTime,
    required double duration,
    required int width, // e.g., 320 or 480
  }) async {
    final inputFile = File(inputPath);
    if (!await inputFile.exists()) {
      throw Exception('Input video file does not exist at $inputPath');
    }

    final root = await getApplicationDocumentsDirectory();
    final imagesFolder = Directory(p.join(root.path, 'Duck Downloader', 'Images'));
    await imagesFolder.create(recursive: true);

    final inputBasename = p.basenameWithoutExtension(inputPath);
    final outputFilename = '${inputBasename}_clip.gif';
    final outputPath = p.join(imagesFolder.path, outputFilename);

    var finalOutputPath = outputPath;
    var counter = 1;
    while (await File(finalOutputPath).exists()) {
      finalOutputPath = p.join(imagesFolder.path, '${inputBasename}_clip_$counter.gif');
      counter++;
    }

    // High quality palette-based GIF generation using lanczos scaling
    // -ss is placed before -i for fast seeking
    final List<String> args = [
      '-y',
      '-ss', startTime.toStringAsFixed(3),
      '-t', duration.toStringAsFixed(3),
      '-i', inputPath,
      '-vf', 'fps=10,scale=$width:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse',
      finalOutputPath
    ];

    final session = await FFmpegKit.executeWithArguments(args);
    final returnCode = await session.getReturnCode();

    if (ReturnCode.isSuccess(returnCode)) {
      final outputFile = File(finalOutputPath);
      if (await outputFile.exists() && await outputFile.length() > 0) {
        return finalOutputPath;
      } else {
        throw Exception('Generated GIF file is empty.');
      }
    } else {
      final logs = await session.getAllLogsAsString();
      throw Exception('FFmpeg GIF creation failed: ${logs?.trim() ?? 'unknown error'}');
    }
  }
}
