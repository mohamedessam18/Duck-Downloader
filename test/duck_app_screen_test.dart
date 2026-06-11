import 'dart:io';

import 'package:duck_downloader/models/download_models.dart';
import 'package:duck_downloader/screens/duck_app_screen.dart';
import 'package:duck_downloader/services/api_client.dart';
import 'package:duck_downloader/services/clipboard_service.dart';
import 'package:duck_downloader/services/download_store.dart';
import 'package:duck_downloader/services/file_service.dart';
import 'package:duck_downloader/services/license_store.dart';
import 'package:duck_downloader/state/downloads_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('duck_app_screen_test_');
    Hive.init(hiveDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  testWidgets('metadata options state scrolls instead of overflowing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(640, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final box = await Hive.openBox('duck-downloads');
    await box.clear();
    addTearDown(box.close);

    final controller =
        DuckDownloadsController(
            api: DuckApiClient(),
            clipboard: DuckClipboardService(),
            files: DuckFileService(),
            store: DownloadStore(box),
            licenseStore: LicenseStore(box),
          )
          ..flow = DuckFlow.ready
          ..status = 'Choose video or audio'
          ..quality = '720p'
          ..metadata = const MediaMetadata(
            url: 'https://example.com/watch',
            title:
                'A long title that still needs to fit inside the options card',
            platform: 'Youtube',
            thumbnail: null,
            qualities: [FormatInfo(id: '720', label: '720p')],
            audioFormats: [FormatInfo(id: 'mp3', label: 'MP3')],
          );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: DuckAppScreen(controller: controller)),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Choose video or audio'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('processing downloads show a processing queue state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final box = await Hive.openBox('duck-downloads');
    await box.clear();
    addTearDown(box.close);

    await box.put('downloads', [
      DownloadItem(
        id: 'processing-audio',
        url: 'https://example.com/audio',
        title: 'Converting audio',
        platform: 'Youtube',
        type: DownloadType.audio,
        createdAt: DateTime.utc(2026, 1, 3),
        status: DownloadStatus.processing,
        progress: 99,
        favorite: false,
      ).toJson(),
      DownloadItem(
        id: 'active-video',
        url: 'https://example.com/video',
        title: 'Still downloading',
        platform: 'Youtube',
        type: DownloadType.video,
        createdAt: DateTime.utc(2026, 1, 2),
        status: DownloadStatus.downloading,
        progress: 35,
        favorite: false,
      ).toJson(),
      DownloadItem(
        id: 'completed-audio',
        url: 'https://example.com/done',
        title: 'Already completed',
        platform: 'Youtube',
        type: DownloadType.audio,
        createdAt: DateTime.utc(2026, 1, 1),
        status: DownloadStatus.completed,
        progress: 100,
        favorite: false,
      ).toJson(),
    ]);

    final controller = DuckDownloadsController(
      api: DuckApiClient(),
      clipboard: DuckClipboardService(),
      files: DuckFileService(),
      store: DownloadStore(box),
      licenseStore: LicenseStore(box),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: DuckAppScreen(controller: controller)),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Download Queue'), findsOneWidget);
    expect(find.text('Processing'), findsOneWidget);
    expect(find.text('Converting audio'), findsOneWidget);
    expect(find.text('Still downloading'), findsOneWidget);
    expect(find.text('Already completed'), findsNothing);
  });
}
