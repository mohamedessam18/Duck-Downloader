import 'dart:async';
import 'dart:io';

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
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// A backend whose downloads only finish when the test says so.
///
/// The real one takes minutes; holding each job open here is what makes it
/// possible to look at the queue while it is actually full.
class HeldApiClient extends DuckApiClient {
  HeldApiClient() : super(apiBaseUrl: 'https://api.test');

  final List<String> startedUrls = [];
  final Map<String, StreamController<DownloadStatusUpdate>> _channels = {};

  @override
  Future<String> startDownload({
    required String url,
    required DownloadType type,
    required String quality,
    bool removeMusic = false,
    bool premiumNoWatermark = false,
  }) async {
    startedUrls.add(url);
    return 'backend-${startedUrls.length}';
  }

  @override
  Stream<DownloadStatusUpdate> watchDownload(String id) {
    final channel = StreamController<DownloadStatusUpdate>();
    _channels[id] = channel;
    return channel.stream;
  }

  /// Ends the oldest job that is still running.
  Future<void> finishOldest() async {
    final id = _channels.keys.first;
    final channel = _channels.remove(id)!;
    channel.add(
      const DownloadStatusUpdate(progress: 100, status: DownloadStatus.failed,
          error: 'done for the purposes of this test'),
    );
    await channel.close();
  }
}

class _NoopMediaSaveService extends MediaSaveService {
  @override
  Future<ExternalSaveResult> saveVideo({
    required String path,
    required String filename,
  }) async => const ExternalSaveResult(success: true, uri: 'content://video');

  @override
  Future<ExternalSaveResult> saveAudio({
    required String path,
    required String filename,
    required DownloadType type,
    bool interactive = true,
  }) async => const ExternalSaveResult(success: true, uri: 'content://audio');

  @override
  Future<ExternalSaveResult> saveImage({
    required String path,
    required String filename,
    required String mimeType,
  }) async => const ExternalSaveResult(success: true, uri: 'content://image');
}

class _NoopFileService extends DuckFileService {
  @override
  Future<String> downloadRemoteFile({
    required String url,
    required String filename,
    required DownloadType type,
    void Function(int received, int total)? onProgress,
  }) async => '/tmp/$filename';
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tempDir.path,
        );
    tempDir = await Directory.systemTemp.createTemp('download_queue_');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('runs three downloads at a time and queues the rest', () async {
    final box = await Hive.openBox('download-queue-cap');
    addTearDown(box.close);
    await box.clear();
    final api = HeldApiClient();
    final controller = _controller(box, api);
    addTearDown(controller.dispose);

    controller.batchPlatform = 'Example';
    final urls = List.generate(
      8,
      (index) => 'https://cdn.example.com/clip-$index.jpg',
    );
    await controller.startBatchDownload(
      urls: urls,
      type: DownloadType.image,
      quality: 'Best',
    );
    await pumpEventQueue();

    // Only the cap reaches the backend. Before there was a queue, all eight
    // opened at once.
    expect(api.startedUrls, [
      'https://cdn.example.com/clip-0.jpg',
      'https://cdn.example.com/clip-1.jpg',
      'https://cdn.example.com/clip-2.jpg',
    ]);
    expect(controller.runningDownloadCount, 3);
    expect(controller.queuedDownloadCount, 5);

    // Every one of them is already in the library, so the user can see and
    // cancel work that has not started yet.
    expect(controller.downloads.length, 8);
    expect(
      controller.downloads
          .where((item) => item.status == DownloadStatus.queued)
          .length,
      5,
    );

    // A finished download hands its slot to the next in line, in order.
    await api.finishOldest();
    await pumpEventQueue();
    expect(api.startedUrls.last, 'https://cdn.example.com/clip-3.jpg');
    expect(controller.runningDownloadCount, 3);
    expect(controller.queuedDownloadCount, 4);
  });

  test('a socket that closes without a verdict frees its slot', () async {
    final box = await Hive.openBox('download-queue-silent-close');
    addTearDown(box.close);
    await box.clear();
    final api = _SilentCloseApiClient();
    final controller = _controller(box, api);
    addTearDown(controller.dispose);

    controller.batchPlatform = 'Example';
    await controller.startBatchDownload(
      urls: List.generate(
        5,
        (index) => 'https://cdn.example.com/clip-$index.jpg',
      ),
      type: DownloadType.image,
      quality: 'Best',
    );
    for (var i = 0; i < 40; i++) {
      if (controller.queuedDownloadCount == 0 &&
          controller.runningDownloadCount == 0) {
        break;
      }
      await pumpEventQueue(times: 5);
    }

    // A server that hangs up without saying completed or failed used to hold
    // its slot forever, and three of those stopped the queue for good.
    expect(api.startedUrls.length, 5);
    expect(controller.runningDownloadCount, 0);
    expect(controller.queuedDownloadCount, 0);
    expect(
      controller.downloads.every(
        (item) => item.status == DownloadStatus.failed,
      ),
      isTrue,
    );
  });

  test('Premium raises the cap, and buying it starts the extra downloads',
      () async {
    final box = await Hive.openBox('download-queue-premium');
    addTearDown(box.close);
    await box.clear();
    final api = HeldApiClient();
    final controller = _controller(box, api);
    addTearDown(controller.dispose);

    controller.batchPlatform = 'Example';
    await controller.startBatchDownload(
      urls: List.generate(
        8,
        (index) => 'https://cdn.example.com/clip-$index.jpg',
      ),
      type: DownloadType.image,
      quality: 'Best',
    );
    await pumpEventQueue();

    // Free: the paywall's "Faster Downloads" has to be a difference from
    // something, and this is the something.
    expect(controller.runningDownloadCount, 3);

    await _grantPremium(box);
    // The manager re-reads storage and tells its listeners, which is what the
    // real purchase flow does when Play confirms.
    await controller.premium.refresh();
    await pumpEventQueue();

    expect(controller.runningDownloadCount, 5);
    expect(api.startedUrls.length, 5);
    // Nothing was restarted or lost in the process.
    expect(controller.downloads.length, 8);
    expect(controller.queuedDownloadCount, 3);
  });

  test('clearing the queue leaves running downloads alone', () async {
    final box = await Hive.openBox('download-queue-clear');
    addTearDown(box.close);
    await box.clear();
    final api = HeldApiClient();
    final controller = _controller(box, api);
    addTearDown(controller.dispose);

    controller.batchPlatform = 'Example';
    await controller.startBatchDownload(
      urls: List.generate(
        7,
        (index) => 'https://cdn.example.com/clip-$index.jpg',
      ),
      type: DownloadType.image,
      quality: 'Best',
    );
    await pumpEventQueue();

    await controller.clearDownloadQueue();

    expect(controller.queuedDownloadCount, 0);
    expect(controller.runningDownloadCount, 3);
    // The three already costing bandwidth survive; the four that had not
    // started are gone from the library too.
    expect(controller.downloads.length, 3);
  });
}

/// A backend that accepts the job and then hangs up without a verdict.
class _SilentCloseApiClient extends DuckApiClient {
  _SilentCloseApiClient() : super(apiBaseUrl: 'https://api.test');

  final List<String> startedUrls = [];

  @override
  Future<String> startDownload({
    required String url,
    required DownloadType type,
    required String quality,
    bool removeMusic = false,
    bool premiumNoWatermark = false,
  }) async {
    startedUrls.add(url);
    return 'backend-${startedUrls.length}';
  }

  @override
  Stream<DownloadStatusUpdate> watchDownload(String id) => const Stream.empty();
}

/// Writes the record a confirmed purchase leaves behind.
///
/// The lifetime product on purpose: it is the one that never ages out, so the
/// test cannot start failing a week from whenever it was written.
Future<void> _grantPremium(Box box) async {
  await box.put('subscriptionActive', true);
  await box.put('subscriptionProductId', 'duck_pro_lifetime');
  await box.put('subscriptionPurchaseId', 'test-purchase');
  await box.put(
    'subscriptionVerifiedAt',
    DateTime.now().toUtc().toIso8601String(),
  );
}

DuckDownloadsController _controller(Box box, DuckApiClient api) {
  return DuckDownloadsController(
    api: api,
    clipboard: DuckClipboardService(),
    files: _NoopFileService(),
    mediaSaver: _NoopMediaSaveService(),
    store: DownloadStore(box),
    premiumManager: PremiumManager(
      subscriptions: SubscriptionService(),
      purchases: PurchaseRepository(box),
    ),
    initializePremium: false,
    initializePlatformServices: false,
  );
}
