import 'package:duck_downloader/models/download_models.dart';
import 'package:duck_downloader/services/api_client.dart';
import 'package:duck_downloader/services/clipboard_service.dart';
import 'package:duck_downloader/services/download_store.dart';
import 'package:duck_downloader/services/file_service.dart';
import 'package:duck_downloader/services/media_save_service.dart';
import 'package:duck_downloader/services/premium_manager.dart';
import 'package:duck_downloader/services/purchase_repository.dart';
import 'package:duck_downloader/services/subscription_service.dart';
import 'package:duck_downloader/state/downloads_controller.dart';
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

  DownloadItem completedItem({
    required String id,
    required DownloadType type,
    String? filePath,
  }) {
    return DownloadItem(
      id: id,
      url: 'https://example.com/$id',
      title: 'Item $id',
      platform: 'Example',
      type: type,
      filePath: filePath ?? '/tmp/$id',
      createdAt: DateTime.utc(2026),
      status: DownloadStatus.completed,
      progress: 100,
      favorite: false,
    );
  }

  test('openPlayer stores gallery and queue context', () async {
    final controller = createController();
    addTearDown(controller.dispose);

    final imageA = completedItem(id: 'img-a', type: DownloadType.image);
    final imageB = completedItem(id: 'img-b', type: DownloadType.image);
    final gallery = [imageA, imageB];

    controller.openPlayer(imageA, galleryItems: gallery);

    expect(controller.playerItem?.id, 'img-a');
    expect(controller.playerGalleryItems, gallery);
  });

  test('openPlayerById switches to matching library tab', () async {
    final image = completedItem(id: 'img-1', type: DownloadType.image);
    final video = completedItem(id: 'vid-1', type: DownloadType.video);
    final audio = completedItem(id: 'aud-1', type: DownloadType.audio);

    await DownloadStore(box).writeDownloads([image, video, audio]);
    final controller = createController();
    addTearDown(controller.dispose);

    controller.openPlayerById('img-1');

    expect(controller.tab, DuckTab.images);
    expect(controller.playerItem?.id, 'img-1');
  });

  test('closePlayer clears gallery context', () {
    final controller = createController();
    addTearDown(controller.dispose);

    final image = completedItem(id: 'img-1', type: DownloadType.image);
    controller.openPlayer(image, galleryItems: [image]);
    controller.closePlayer();

    expect(controller.playerItem, isNull);
    expect(controller.playerGalleryItems, isNull);
  });

  test('markAudioBackgroundReady is idempotent', () async {
    final controller = createController();
    addTearDown(controller.dispose);

    await controller.markAudioBackgroundReady();
    await controller.markAudioBackgroundReady();
    expect(controller.audioBackgroundReady, isTrue);
  });

  test('video resume position round-trips through store', () async {
    final store = DownloadStore(box);
    await store.writeVideoResumePosition('vid-1', 45000);
    expect(store.readVideoResumePositions()['vid-1'], 45000);
  });
}
