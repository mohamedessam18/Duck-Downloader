import 'package:duck_downloader/models/download_models.dart';
import 'package:duck_downloader/screens/duck_app_screen.dart';
import 'package:duck_downloader/services/api_client.dart';
import 'package:duck_downloader/services/clipboard_service.dart';
import 'package:duck_downloader/services/download_store.dart';
import 'package:duck_downloader/services/file_service.dart';
import 'package:duck_downloader/services/premium_manager.dart';
import 'package:duck_downloader/services/purchase_repository.dart';
import 'package:duck_downloader/services/subscription_service.dart';
import 'package:duck_downloader/services/media_save_service.dart';
import 'package:duck_downloader/services/youtube_explode_service.dart';
import 'package:duck_downloader/state/downloads_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class FakeBox extends Fake implements Box {
  final Map<dynamic, dynamic> _storage = {};

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) {
    return _storage.containsKey(key) ? _storage[key] : defaultValue;
  }

  @override
  Future<void> put(dynamic key, dynamic value) async {
    _storage[key] = value;
  }

  @override
  Future<void> delete(dynamic key) async {
    _storage.remove(key);
  }

  @override
  Future<int> clear() async {
    _storage.clear();
    return 0;
  }

  @override
  Future<void> close() async {}
}

class FakeClipboardService extends DuckClipboardService {
  String? clipboardText;

  @override
  Future<String?> readText() async => clipboardText;
}

class FakeApiClient extends Fake implements DuckApiClient {
  bool extractCalled = false;
  String? extractedUrl;

  @override
  Future<MediaMetadata> extract(String url) async {
    extractCalled = true;
    extractedUrl = url;
    return MediaMetadata(
      url: url,
      title: 'Fake Title',
      platform: 'YouTube',
      qualities: [const FormatInfo(id: 'best', label: 'Best')],
      audioFormats: [],
    );
  }
}

class FakeYouTubeExplodeService extends Fake implements YouTubeExplodeService {
  bool extractMetadataCalled = false;
  String? extractedUrl;

  @override
  Future<MediaMetadata?> extractMetadata(String url) async {
    extractMetadataCalled = true;
    extractedUrl = url;
    return MediaMetadata(
      url: url,
      title: 'Fake YouTube Video',
      platform: 'YouTube',
      qualities: [const FormatInfo(id: 'https://fake-stream-url.com/video.mp4', label: '720p')],
      audioFormats: [],
    );
  }
}


void main() {
  testWidgets('metadata options state scrolls instead of overflowing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(640, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final box = FakeBox();

    final controller =
        DuckDownloadsController(
            api: DuckApiClient(),
            clipboard: DuckClipboardService(),
            files: DuckFileService(),
            mediaSaver: MediaSaveService(),
            store: DownloadStore(box),
            premiumManager: _premiumManager(box),
            initializePremium: false,
            initializePlatformServices: false,
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

    final box = FakeBox();

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
      mediaSaver: MediaSaveService(),
      store: DownloadStore(box),
      premiumManager: _premiumManager(box),
      initializePremium: false,
      initializePlatformServices: false,
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

  testWidgets('clipboard detection displays overlay and dismiss works', (
    tester,
  ) async {
    final box = FakeBox();
    final clipboard = FakeClipboardService()
      ..clipboardText = 'https://youtube.com/watch?v=123';

    final controller = DuckDownloadsController(
      api: DuckApiClient(),
      clipboard: clipboard,
      files: DuckFileService(),
      mediaSaver: MediaSaveService(),
      store: DownloadStore(box),
      premiumManager: _premiumManager(box),
      initializePremium: false,
      initializePlatformServices: false,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: DuckAppScreen(controller: controller)),
    );
    await tester.pump();

    // Verify overlay is visible
    expect(find.text('Link Detected!'), findsOneWidget);
    expect(find.text('https://youtube.com/watch?v=123'), findsOneWidget);

    // Dismiss it
    await tester.tap(find.text('Dismiss'));
    await tester.pump();

    // Verify overlay is gone
    expect(find.text('Link Detected!'), findsNothing);
  });

  testWidgets('clipboard detection extract navigates and loads url', (
    tester,
  ) async {
    // Non-YouTube URL → should still call the backend API (extract)
    final box = FakeBox();
    final clipboard = FakeClipboardService()
      ..clipboardText = 'https://www.tiktok.com/@user/video/abc123/';
    final api = FakeApiClient();

    final controller = DuckDownloadsController(
      api: api,
      clipboard: clipboard,
      files: DuckFileService(),
      mediaSaver: MediaSaveService(),
      store: DownloadStore(box),
      premiumManager: _premiumManager(box),
      initializePremium: false,
      initializePlatformServices: false,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: DuckAppScreen(controller: controller)),
    );
    await tester.pump();

    expect(find.text('Link Detected!'), findsOneWidget);

    // Tap extract
    await tester.tap(find.text('Extract'));
    await tester.pump();

    expect(api.extractCalled, isTrue);
    expect(api.extractedUrl, 'https://www.tiktok.com/@user/video/abc123/');
  });

  testWidgets('YouTube URLs display Google Play policy rejection message', (
    tester,
  ) async {
    // YouTube URL → must NOT call the backend API and must show Play Store policy message
    final box = FakeBox();
    final clipboard = FakeClipboardService()
      ..clipboardText = 'https://youtube.com/watch?v=dQw4w9WgXcQ';
    final api = FakeApiClient();
    final ytExplode = FakeYouTubeExplodeService();

    final controller = DuckDownloadsController(
      api: api,
      clipboard: clipboard,
      files: DuckFileService(),
      mediaSaver: MediaSaveService(),
      store: DownloadStore(box),
      premiumManager: _premiumManager(box),
      ytExplode: ytExplode,
      initializePremium: false,
      initializePlatformServices: false,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: DuckAppScreen(controller: controller)),
    );
    await tester.pump();

    expect(find.text('Link Detected!'), findsOneWidget);

    await tester.tap(find.text('Extract'));
    await tester.pump();

    // Backend must NOT be called for YouTube
    expect(api.extractCalled, isFalse);
    expect(controller.status, 'YouTube downloads are not supported under Google Play policies.');
  });


  testWidgets('navigation to images tab works and shows empty library', (
    tester,
  ) async {
    final box = FakeBox();
    final controller = DuckDownloadsController(
      api: DuckApiClient(),
      clipboard: DuckClipboardService(),
      files: DuckFileService(),
      mediaSaver: MediaSaveService(),
      store: DownloadStore(box),
      premiumManager: _premiumManager(box),
      initializePremium: false,
      initializePlatformServices: false,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: DuckAppScreen(controller: controller)),
    );
    await tester.pump();

    // Tap IMAGES tab in bottom nav (last of the two IMAGES texts)
    await tester.tap(find.text('IMAGES').last);
    await tester.pump();

    expect(controller.tab, DuckTab.images);
    expect(find.text('No downloaded images yet.'), findsOneWidget);
  });
}

PremiumManager _premiumManager(Box box) {
  return PremiumManager(
    subscriptions: SubscriptionService(),
    purchases: PurchaseRepository(box),
  );
}
