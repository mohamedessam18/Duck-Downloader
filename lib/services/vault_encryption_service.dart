import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/download_models.dart';

class VaultEncryptionService {
  static const String _vaultDirName = '.Vault';

  /// Generates a random unique name with no extension for file obfuscation
  static String _generateObfuscatedName() {
    final rand = Random();
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final randomValue = rand.nextInt(1000000);
    return 'vault_${timestamp}_$randomValue.enc';
  }

  /// Sanitizes filename
  static String _sanitizeFilename(String value) {
    final sanitized = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]+'), '_')
        .trim();
    return sanitized.isEmpty ? 'duck-download' : sanitized;
  }

  /// Moves a file to the secure vault, renaming it to a random obfuscated name with no extension
  static Future<String> encryptAndMoveToVault({
    required String currentPath,
    required String originalFilename,
  }) async {
    final root = await getApplicationDocumentsDirectory();
    final vaultFolder = Directory(p.join(root.path, 'Duck Downloader', _vaultDirName));
    await vaultFolder.create(recursive: true);

    final obfuscatedName = _generateObfuscatedName();
    final destPath = p.join(vaultFolder.path, obfuscatedName);

    final sourceFile = File(currentPath);
    if (await sourceFile.exists()) {
      await sourceFile.rename(destPath);
    } else {
      throw Exception('Source file does not exist at $currentPath');
    }
    return destPath;
  }

  /// Restores a file from the secure vault back to its public folder with original name and extension
  static Future<String> decryptAndMoveFromVault({
    required String currentPath,
    required String originalFilename,
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

    final safeName = _sanitizeFilename(originalFilename);
    final destPath = p.join(destFolder.path, safeName);

    final sourceFile = File(currentPath);
    if (await sourceFile.exists()) {
      await sourceFile.rename(destPath);
    } else {
      throw Exception('Vault file does not exist at $currentPath');
    }
    return destPath;
  }

  /// Copies a vault file to the temp directory with its original extension for exporting
  static Future<String> getDecryptedTempPath({
    required String vaultPath,
    required String originalFilename,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final safeName = _sanitizeFilename(originalFilename);
    final destPath = p.join(tempDir.path, 'export_temp_${DateTime.now().millisecondsSinceEpoch}_$safeName');
    
    final sourceFile = File(vaultPath);
    if (await sourceFile.exists()) {
      await sourceFile.copy(destPath);
    } else {
      throw Exception('Vault file does not exist at $vaultPath');
    }
    return destPath;
  }
}
