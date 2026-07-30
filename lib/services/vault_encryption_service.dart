import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/download_models.dart';

class VaultEncryptionService {
  VaultEncryptionService._();

  static const _vaultDirName = '.Vault';
  static const _magic = <int>[68, 68, 86, 50]; // DDV2
  static const _chunkSize = 1024 * 1024;
  static const _pinIterations = 80000;
  static const _legacyPinIterations = 310000;
  static const _saltKey = 'vault.pin.salt';
  static const _pinEnvelopeKey = 'vault.pin.envelope';
  static const _deviceKey = 'vault.device.master-key';
  static const _decoySaltKey = 'vault.decoy.salt';
  static const _decoyEnvelopeKey = 'vault.decoy.envelope';

  static final _random = Random.secure();
  static final _cipher = AesGcm.with256bits();
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static SecretKey? _sessionKey;
  static bool _configured = false;
  static bool _decoyConfigured = false;

  static bool get isConfigured => _configured;
  static bool get isDecoyConfigured => _decoyConfigured;
  static bool get isUnlocked => _sessionKey != null;

  static Future<void> initialize() async {
    final salt = await _storage.read(key: _saltKey);
    final envelope = await _storage.read(key: _pinEnvelopeKey);
    _configured = salt != null && envelope != null;
    final decoySalt = await _storage.read(key: _decoySaltKey);
    final decoyEnvelope = await _storage.read(key: _decoyEnvelopeKey);
    _decoyConfigured = decoySalt != null && decoyEnvelope != null;
  }

  static Future<void> configurePin(String pin) async {
    _validatePin(pin);
    if (_configured && !isUnlocked) {
      throw StateError('Vault must be unlocked before changing PIN.');
    }
    final salt = _randomBytes(16);
    final pinKey = await _derivePinKey(pin, salt);
    final masterKey = _sessionKey ?? await _cipher.newSecretKey();
    final masterKeyBytes = await masterKey.extractBytes();
    final envelope = await _encryptBytes(masterKeyBytes, pinKey);

    await _storage.write(key: _saltKey, value: base64UrlEncode(salt));
    await _storage.write(
      key: _pinEnvelopeKey,
      value: base64UrlEncode(envelope),
    );
    await _storage.write(
      key: _deviceKey,
      value: base64UrlEncode(masterKeyBytes),
    );
    _sessionKey = SecretKey(masterKeyBytes);
    _configured = true;
  }

  static Future<bool> unlockWithPin(String pin) async {
    try {
      final saltValue = await _storage.read(key: _saltKey);
      final envelopeValue = await _storage.read(key: _pinEnvelopeKey);
      if (saltValue == null || envelopeValue == null) return false;
      final salt = base64Url.decode(saltValue);
      final envelope = base64Url.decode(envelopeValue);

      for (final iterations in [_pinIterations, _legacyPinIterations]) {
        try {
          final pinKey = await _derivePinKey(pin, salt, iterations: iterations);
          final masterKeyBytes = await _decryptBytes(envelope, pinKey);
          if (masterKeyBytes.length != 32) continue;
          _sessionKey = SecretKey(masterKeyBytes);
          _configured = true;
          if (iterations != _pinIterations) await configurePin(pin);
          return true;
        } catch (_) {}
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> configureDecoyPin(String pin) async {
    _validatePin(pin);
    final salt = _randomBytes(16);
    final pinKey = await _derivePinKey(pin, salt);
    final verificationSecret = _randomBytes(32);
    final envelope = await _encryptBytes(verificationSecret, pinKey);
    await _storage.write(key: _decoySaltKey, value: base64UrlEncode(salt));
    await _storage.write(
      key: _decoyEnvelopeKey,
      value: base64UrlEncode(envelope),
    );
    _decoyConfigured = true;
  }

  static Future<bool> unlockWithDecoyPin(String pin) async {
    try {
      final saltValue = await _storage.read(key: _decoySaltKey);
      final envelopeValue = await _storage.read(key: _decoyEnvelopeKey);
      if (saltValue == null || envelopeValue == null) return false;
      final pinKey = await _derivePinKey(pin, base64Url.decode(saltValue));
      final verificationSecret = await _decryptBytes(
        base64Url.decode(envelopeValue),
        pinKey,
      );
      return verificationSecret.length == 32;
    } catch (_) {
      return false;
    }
  }

  /// Call only after the OS biometric prompt succeeds.
  static Future<bool> unlockWithDeviceKey() async {
    try {
      final encoded = await _storage.read(key: _deviceKey);
      if (encoded == null) return false;
      final bytes = base64Url.decode(encoded);
      if (bytes.length != 32) return false;
      _sessionKey = SecretKey(bytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  static void lock() {
    _sessionKey = null;
  }

  static Future<void> deleteVaultKeys() async {
    lock();
    _configured = false;
    await _storage.delete(key: _saltKey);
    await _storage.delete(key: _pinEnvelopeKey);
    await _storage.delete(key: _deviceKey);
    await _storage.delete(key: _decoySaltKey);
    await _storage.delete(key: _decoyEnvelopeKey);
    _decoyConfigured = false;
  }

  static Future<String> encryptAndMoveToVault({
    required String currentPath,
    required String originalFilename,
  }) async {
    final source = File(currentPath);
    final encryptedPath = await encryptToVault(
      currentPath: currentPath,
      originalFilename: originalFilename,
    );
    try {
      await source.delete();
      return encryptedPath;
    } catch (_) {
      final encrypted = File(encryptedPath);
      if (await encrypted.exists()) await encrypted.delete();
      rethrow;
    }
  }

  // Leaves the original untouched so callers can commit metadata first.
  static Future<String> encryptToVault({
    required String currentPath,
    required String originalFilename,
  }) async {
    final key = _requireSessionKey();
    final source = File(currentPath);
    if (!await source.exists()) {
      throw Exception('Source file does not exist at $currentPath');
    }
    final root = await getApplicationDocumentsDirectory();
    final vaultFolder = Directory(
      p.join(root.path, 'Duck Downloader', _vaultDirName),
    );
    await vaultFolder.create(recursive: true);
    final destination = File(
      p.join(vaultFolder.path, _generateObfuscatedName()),
    );
    final partial = File('${destination.path}.partial');
    try {
      await _encryptFile(source, partial, key);
      await partial.rename(destination.path);
      return destination.path;
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  static Future<String> decryptAndMoveFromVault({
    required String currentPath,
    required String originalFilename,
    required DownloadType type,
  }) async {
    final root = await getApplicationDocumentsDirectory();
    final destinationFolder = Directory(
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
    await destinationFolder.create(recursive: true);

    final destination = File(
      p.join(
        destinationFolder.path,
        _uniqueName(destinationFolder, _sanitizeFilename(originalFilename)),
      ),
    );
    await _decryptFile(File(currentPath), destination, deleteSource: true);
    return destination.path;
  }

  static Future<String> getDecryptedTempPath({
    required String vaultPath,
    required String originalFilename,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final destination = File(
      p.join(
        tempDir.path,
        'vault_${DateTime.now().microsecondsSinceEpoch}_${_sanitizeFilename(originalFilename)}',
      ),
    );
    await _decryptFile(File(vaultPath), destination, deleteSource: false);
    return destination.path;
  }

  static Future<void> writePrivateDownloadIndex(
    List<Map<String, dynamic>> entries,
  ) async {
    final key = _requireSessionKey();
    final root = await getApplicationDocumentsDirectory();
    final vaultFolder = Directory(
      p.join(root.path, 'Duck Downloader', _vaultDirName),
    );
    await vaultFolder.create(recursive: true);
    final destination = File(p.join(vaultFolder.path, '.private-index'));
    final partial = File('${destination.path}.partial');
    final encrypted = await _encryptBytes(
      utf8.encode(jsonEncode(entries)),
      key,
    );
    try {
      await partial.writeAsString(base64UrlEncode(encrypted), flush: true);
      final backup = File('${destination.path}.backup');
      if (await backup.exists()) await backup.delete();
      if (await destination.exists()) await destination.rename(backup.path);
      try {
        await partial.rename(destination.path);
        if (await backup.exists()) await backup.delete();
      } catch (_) {
        if (!await destination.exists() && await backup.exists()) {
          await backup.rename(destination.path);
        }
        rethrow;
      }
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  static Future<List<Map<String, dynamic>>> readPrivateDownloadIndex() async {
    final key = _requireSessionKey();
    final root = await getApplicationDocumentsDirectory();
    final vaultPath = p.join(root.path, 'Duck Downloader', _vaultDirName);
    final index = File(p.join(vaultPath, '.private-index'));
    final backup = File(p.join(vaultPath, '.private-index.backup'));
    final source = await index.exists() ? index : backup;
    if (!await source.exists()) return const [];
    try {
      final encrypted = base64Url.decode(await source.readAsString());
      final decoded = jsonDecode(
        utf8.decode(await _decryptBytes(encrypted, key)),
      );
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map) Map<String, dynamic>.from(entry),
      ];
    } catch (_) {
      throw const FormatException('Unable to read the encrypted Vault index.');
    }
  }

  static Future<bool> isEncryptedFile(String path) async {
    final file = File(path);
    if (!await file.exists() || await file.length() < _magic.length)
      return false;
    final access = await file.open();
    try {
      return _sameBytes(await access.read(_magic.length), _magic);
    } finally {
      await access.close();
    }
  }

  static Future<void> _encryptFile(
    File source,
    File output,
    SecretKey key,
  ) async {
    final input = await source.open(mode: FileMode.read);
    final destination = await output.open(mode: FileMode.write);
    try {
      await destination.writeFrom(_magic);
      while (true) {
        final plain = await input.read(_chunkSize);
        if (plain.isEmpty) break;
        final nonce = _randomBytes(12);
        final box = await _cipher.encrypt(plain, secretKey: key, nonce: nonce);
        await destination.writeFrom(_uint32(box.cipherText.length));
        await destination.writeFrom(nonce);
        await destination.writeFrom(box.cipherText);
        await destination.writeFrom(box.mac.bytes);
      }
    } finally {
      await input.close();
      await destination.close();
    }
  }

  static Future<void> _decryptFile(
    File source,
    File destination, {
    required bool deleteSource,
  }) async {
    final key = _requireSessionKey();
    if (!await source.exists()) {
      throw Exception('Vault file does not exist at ${source.path}');
    }
    final partial = File('${destination.path}.partial');
    final input = await source.open(mode: FileMode.read);
    final output = await partial.open(mode: FileMode.write);
    try {
      final header = await input.read(_magic.length);
      if (!_sameBytes(header, _magic)) {
        // Legacy vault files were only obfuscated, not encrypted.
        await output.writeFrom(header);
        while (true) {
          final bytes = await input.read(_chunkSize);
          if (bytes.isEmpty) break;
          await output.writeFrom(bytes);
        }
      } else {
        while (true) {
          final lengthBytes = await input.read(4);
          if (lengthBytes.isEmpty) break;
          if (lengthBytes.length != 4)
            throw const FormatException('Invalid vault chunk length.');
          final length = _readUint32(lengthBytes);
          if (length < 0 || length > _chunkSize)
            throw const FormatException('Invalid vault chunk.');
          final nonce = await input.read(12);
          final cipherText = await input.read(length);
          final mac = await input.read(16);
          if (nonce.length != 12 ||
              cipherText.length != length ||
              mac.length != 16) {
            throw const FormatException('Truncated vault file.');
          }
          final plain = await _cipher.decrypt(
            SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
            secretKey: key,
          );
          await output.writeFrom(plain);
        }
      }
      await output.close();
      await input.close();
      await partial.rename(destination.path);
      if (deleteSource) await source.delete();
    } catch (_) {
      await output.close();
      await input.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  static Future<SecretKey> _derivePinKey(
    String pin,
    List<int> salt, {
    int iterations = _pinIterations,
  }) {
    return Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    ).deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: salt);
  }

  static Future<List<int>> _encryptBytes(List<int> bytes, SecretKey key) async {
    final nonce = _randomBytes(12);
    final box = await _cipher.encrypt(bytes, secretKey: key, nonce: nonce);
    return [...nonce, ...box.mac.bytes, ...box.cipherText];
  }

  static Future<List<int>> _decryptBytes(List<int> bytes, SecretKey key) {
    if (bytes.length < 28)
      throw const FormatException('Invalid vault key envelope.');
    return _cipher.decrypt(
      SecretBox(
        bytes.sublist(28),
        nonce: bytes.sublist(0, 12),
        mac: Mac(bytes.sublist(12, 28)),
      ),
      secretKey: key,
    );
  }

  static SecretKey _requireSessionKey() {
    final key = _sessionKey;
    if (key == null) throw StateError('Unlock the Secure Vault first.');
    return key;
  }

  static List<int> _randomBytes(int count) =>
      List<int>.generate(count, (_) => _random.nextInt(256));

  static List<int> _uint32(int value) => [
    (value >> 24) & 0xff,
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  ];

  static int _readUint32(List<int> bytes) =>
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  static String _generateObfuscatedName() =>
      'vault_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1 << 32)}.ddv';

  static String _uniqueName(Directory folder, String filename) {
    final extension = p.extension(filename);
    final base = p.basenameWithoutExtension(filename);
    var candidate = filename;
    var index = 1;
    while (File(p.join(folder.path, candidate)).existsSync()) {
      candidate = '${base}_$index$extension';
      index++;
    }
    return candidate;
  }

  static String _sanitizeFilename(String value) {
    final sanitized = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]+'), '_')
        .trim();
    return sanitized.isEmpty ? 'duck-download' : sanitized;
  }

  static void _validatePin(String pin) {
    if (!RegExp(r'^\d{4,12}$').hasMatch(pin)) {
      throw ArgumentError('Vault PIN must contain 4 to 12 digits.');
    }
  }
}
