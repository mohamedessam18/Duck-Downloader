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
        type == DownloadType.audio
            ? 'Audios'
            : type == DownloadType.image
            ? 'Images'
            : 'Videos',
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

  Future<String> moveFileToVault({
    required String currentPath,
    required String filename,
  }) async {
    final root = await getApplicationDocumentsDirectory();
    final vaultFolder = Directory(
      p.join(root.path, 'Duck Downloader', '.Vault'),
    );
    await vaultFolder.create(recursive: true);
    final safeName = _sanitizeFilename(filename);
    final destPath = p.join(vaultFolder.path, safeName);
    final sourceFile = File(currentPath);
    if (await sourceFile.exists()) {
      await sourceFile.rename(destPath);
    } else {
      throw Exception('Source file does not exist at $currentPath');
    }
    return destPath;
  }

  Future<String> moveFileFromVault({
    required String currentPath,
    required String filename,
    required DownloadType type,
  }) async {
    final root = await getApplicationDocumentsDirectory();
    final destFolder = Directory(
      p.join(
        root.path,
        'Duck Downloader',
        type == DownloadType.audio
            ? 'Audios'
            : type == DownloadType.image
            ? 'Images'
            : 'Videos',
      ),
    );
    await destFolder.create(recursive: true);
    final safeName = _sanitizeFilename(filename);
    final destPath = p.join(destFolder.path, safeName);
    final sourceFile = File(currentPath);
    if (await sourceFile.exists()) {
      await sourceFile.rename(destPath);
    } else {
      throw Exception('Source file does not exist in vault at $currentPath');
    }
    return destPath;
  }

  Future<void> updateMp3Metadata({
    required String filePath,
    required String title,
    required String artist,
    required String album,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return;

    final length = await file.length();
    bool hasTag = false;
    if (length >= 128) {
      final access = await file.open(mode: FileMode.read);
      try {
        await access.setPosition(length - 128);
        final header = await access.read(3);
        if (header.length == 3 &&
            header[0] == 84 && // 'T'
            header[1] == 65 && // 'A'
            header[2] == 71) {
          // 'G'
          hasTag = true;
        }
      } catch (_) {
      } finally {
        await access.close();
      }
    }

    final tagBytes = List<int>.filled(128, 0);
    // Write 'TAG'
    tagBytes[0] = 84;
    tagBytes[1] = 65;
    tagBytes[2] = 71;

    // Write title (offset 3, length 30)
    final titleBytes = _fixedLengthBytes(title, 30);
    for (int i = 0; i < 30; i++) {
      tagBytes[3 + i] = titleBytes[i];
    }

    // Write artist (offset 33, length 30)
    final artistBytes = _fixedLengthBytes(artist, 30);
    for (int i = 0; i < 30; i++) {
      tagBytes[33 + i] = artistBytes[i];
    }

    // Write album (offset 63, length 30)
    final albumBytes = _fixedLengthBytes(album, 30);
    for (int i = 0; i < 30; i++) {
      tagBytes[63 + i] = albumBytes[i];
    }

    if (hasTag) {
      final rwAccess = await file.open(mode: FileMode.write);
      try {
        await rwAccess.setPosition(length - 128);
        await rwAccess.writeFrom(tagBytes);
      } finally {
        await rwAccess.close();
      }
    } else {
      final appendAccess = await file.open(mode: FileMode.writeOnlyAppend);
      try {
        await appendAccess.writeFrom(tagBytes);
      } finally {
        await appendAccess.close();
      }
    }
  }

  List<int> _fixedLengthBytes(String val, int length) {
    final result = List<int>.filled(length, 0);
    for (int i = 0; i < val.length && i < length; i++) {
      final code = val.codeUnitAt(i);
      result[i] = code < 256 ? code : 63; // '?' for out of bounds
    }
    return result;
  }
}
