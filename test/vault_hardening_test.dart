import 'dart:io';

import 'package:duck_downloader/services/vault_encryption_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the vault's security posture. Each of these encodes a weakening that
/// actually shipped at some point, so a future refactor cannot quietly undo it.
void main() {
  final secureStorage = <String, String>{};

  late Directory documents;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    documents = Directory.systemTemp.createTempSync('duck-vault-test');
    addTearDown(() {
      if (documents.existsSync()) documents.deleteSync(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => switch (call.method) {
            'getApplicationDocumentsDirectory' => documents.path,
            'getTemporaryDirectory' => documents.path,
            _ => null,
          },
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = call.arguments;
            final key = args is Map ? args['key'] as String? : null;
            switch (call.method) {
              case 'read':
                return key == null ? null : secureStorage[key];
              case 'write':
                if (key != null) {
                  secureStorage[key] = (args as Map)['value'] as String;
                }
                return null;
              case 'delete':
                if (key != null) secureStorage.remove(key);
                return null;
              case 'deleteAll':
                secureStorage.clear();
                return null;
              case 'readAll':
                return secureStorage;
            }
            return null;
          },
        );
  });

  setUp(() async {
    secureStorage.clear();
    await VaultEncryptionService.deleteVaultKeys();
  });

  group('PIN policy', () {
    test('rejects PINs shorter than the documented minimum', () {
      expect(VaultEncryptionService.minimumPinLength, greaterThanOrEqualTo(6));
      // Four digits is only 10,000 candidates — no work factor rescues it.
      expect(
        () => VaultEncryptionService.configurePin('1234'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VaultEncryptionService.configurePin('12345'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects non-numeric and over-long PINs', () {
      expect(
        () => VaultEncryptionService.configurePin('abcdef'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => VaultEncryptionService.configurePin('1234567890123'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('key lifecycle', () {
    test('reports a brand-new vault only on first configuration', () async {
      // A new master key means any leftover vault content is unreadable, which
      // is what tells the controller it is safe to clear the stale index.
      expect(await VaultEncryptionService.configurePin('123456'), isTrue);

      // Changing the PIN while unlocked re-wraps the *same* master key, so the
      // existing vault must stay readable.
      expect(await VaultEncryptionService.configurePin('654321'), isFalse);
    });

    test('unlocks with the current PIN and refuses the old one', () async {
      await VaultEncryptionService.configurePin('123456');
      VaultEncryptionService.lock();
      expect(VaultEncryptionService.isUnlocked, isFalse);

      expect(await VaultEncryptionService.unlockWithPin('999999'), isFalse);
      expect(await VaultEncryptionService.unlockWithPin('123456'), isTrue);
      expect(VaultEncryptionService.isUnlocked, isTrue);
    });

    test('a wrong PIN leaves the vault locked', () async {
      await VaultEncryptionService.configurePin('123456');
      VaultEncryptionService.lock();

      await VaultEncryptionService.unlockWithPin('000000');
      expect(VaultEncryptionService.isUnlocked, isFalse);
    });
  });

  test('round-trips bytes through AES-GCM', () async {
    await VaultEncryptionService.configurePin('123456');
    // Encrypting the metadata index and reading it straight back is the
    // narrowest end-to-end check that the cipher and key agree.
    await VaultEncryptionService.writePrivateDownloadIndex([
      {'id': 'a', 'title': 'secret'},
    ]);
    final entries = await VaultEncryptionService.readPrivateDownloadIndex();

    expect(entries.single['title'], 'secret');
  });

  test('a new master key makes the previous index unreadable', () async {
    await VaultEncryptionService.configurePin('123456');
    await VaultEncryptionService.writePrivateDownloadIndex([
      {'id': 'a', 'title': 'secret'},
    ]);

    // Simulate the vault being re-created from scratch: keys are gone, so the
    // index left on disk can never be decrypted again. Reading it must fail
    // loudly rather than return empty, which is what the controller's recovery
    // path keys off.
    await VaultEncryptionService.deleteVaultKeys();
    secureStorage.clear();
    await VaultEncryptionService.configurePin('654321');

    await expectLater(
      VaultEncryptionService.readPrivateDownloadIndex(),
      throwsA(isA<FormatException>()),
    );

    // …and clearing it restores a working vault.
    await VaultEncryptionService.resetPrivateDownloadIndex();
    expect(await VaultEncryptionService.readPrivateDownloadIndex(), isEmpty);
  });
}
