import 'dart:io';

import 'package:duck_downloader/services/license_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('license_store_test_');
    Hive.init(hiveDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  test('saves and clears lifetime pro license state', () async {
    final box = await Hive.openBox('license-store-test');
    addTearDown(box.close);
    await box.clear();

    final store = LicenseStore(box);
    expect(store.isActive, isFalse);
    expect(store.licenseKey, isNull);

    await store.save(licenseKey: ' DUCK-PRO-1234 ', active: true);
    expect(store.isActive, isTrue);
    expect(store.licenseKey, 'DUCK-PRO-1234');

    await store.clear();
    expect(store.isActive, isFalse);
    expect(store.licenseKey, isNull);
  });
}
