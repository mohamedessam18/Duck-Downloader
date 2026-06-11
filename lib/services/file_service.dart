import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/download_models.dart';

class DuckFileService {
  DuckFileService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<String> downloadRemoteFile({
    required String url,
    required String filename,
    required DownloadType type,
  }) async {
    final root = await getApplicationDocumentsDirectory();
    final folder = Directory(
      p.join(
        root.path,
        'Duck Downloader',
        type == DownloadType.audio ? 'Audios' : 'Videos',
      ),
    );
    await folder.create(recursive: true);
    final safeName = _sanitizeFilename(filename);
    final filePath = p.join(folder.path, safeName);
    await _dio.download(url, filePath);
    return filePath;
  }

  Future<void> deleteFile(String? filePath) async {
    if (filePath == null) return;
    final file = File(filePath);
    if (await file.exists()) await file.delete();
  }

  Future<void> shareFile(String? filePath) async {
    if (filePath == null) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(filePath)]));
  }

  String _sanitizeFilename(String value) {
    final sanitized = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]+'), '_')
        .trim();
    return sanitized.isEmpty ? 'duck-download' : sanitized;
  }
}
