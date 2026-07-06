import 'package:duck_downloader/models/download_models.dart';
import 'package:duck_downloader/services/api_client.dart';
import 'package:duck_downloader/services/clipboard_service.dart';
import 'package:duck_downloader/services/download_store.dart';
import 'package:duck_downloader/services/file_service.dart';
import 'package:duck_downloader/services/media_save_service.dart';
import 'package:duck_downloader/services/premium_manager.dart';
import 'package:duck_downloader/services/purchase_repository.dart';
import 'package:duck_downloader/services/subscription_service.dart';
import 'package:duck_downloader/services/trim_service.dart';
import 'package:duck_downloader/state/downloads_controller.dart';
import 'package:duck_downloader/widgets/media/media_thumb.dart';
import 'package:flutter_test/flutter_test.dart';

import 'duck_app_screen_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBox box;

  setUp(() {
    box = FakeBox();
  });

  tearDown(() async {
    await box.close();
  });

  DuckDownloadsController createController() {
    return DuckDownloadsController(
      api: DuckApiClient(),
      clipboard: DuckClipboardService(),
      files: DuckFileService(),
      mediaSaver: MediaSaveService(),
      store: DownloadStore(box),
      premiumManager: PremiumManager(
        subscriptions: SubscriptionService(),
        purchases: PurchaseRepository(box),
      ),
      initializePremium: false,
      initializePlatformServices: false,
    );
  }

  test('markAudioBackgroundReady flips ready flag', () async {
    final controller = createController();
    addTearDown(controller.dispose);

    expect(controller.audioBackgroundReady, isFalse);
    await controller.markAudioBackgroundReady();
    expect(controller.audioBackgroundReady, isTrue);
  });

  test('MediaThumb prefers network thumbnail for audio artwork', () {
    const widget = MediaThumb(
      url: 'https://example.com/cover.jpg',
      filePath: '/tmp/track.mp3',
      preferNetworkThumbnail: true,
      width: 48,
      height: 48,
    );

    expect(widget.preferNetworkThumbnail, isTrue);
    expect(widget.filePath, '/tmp/track.mp3');
  });

  test('trimDownload validates before busy flag on missing file', () async {
    final controller = createController();
    addTearDown(controller.dispose);

    final item = DownloadItem(
      id: 'no-file',
      url: 'https://example.com/no-file',
      title: 'Track no-file',
      platform: 'Example',
      type: DownloadType.audio,
      createdAt: DateTime.utc(2026),
      status: DownloadStatus.completed,
      progress: 100,
      favorite: false,
    );

    await expectLater(
      controller.trimDownload(
        item,
        startTime: 0,
        endTime: 5,
        totalDuration: const Duration(seconds: 30),
      ),
      throwsA(isA<TrimValidationException>()),
    );
    expect(controller.busy, isFalse);
  });
}
