import 'dart:io';

import 'package:duck_downloader/services/download_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('download_store_test_');
    Hive.init(hiveDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  test('auto save videos defaults to enabled and persists changes', () async {
    final box = await Hive.openBox('download-store-test');
    addTearDown(box.close);
    await box.clear();

    final store = DownloadStore(box);
    expect(store.readAutoSaveVideos(), isTrue);

    await store.writeAutoSaveVideos(false);
    expect(store.readAutoSaveVideos(), isFalse);
  });
}
