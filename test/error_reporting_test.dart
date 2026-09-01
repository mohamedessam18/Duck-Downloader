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

/// Fails every extraction with one exact message.
class _FailingApi extends DuckApiClient {
  _FailingApi(this.message) : super(apiBaseUrl: 'https://api.test');

  final String message;

  @override
  Future<MediaMetadata> extract(String url) async => throw Exception(message);

  @override
  Future<PlaylistExtractResponse> extractPlaylist(String url) async =>
      throw Exception(message);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  var boxCounter = 0;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('duck-error-reporting');
    Hive.init(hiveDir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  /// Runs one failing extraction and returns the key the user's status shows.
  Future<DuckDownloadsController> report(String message) async {
    final box = await Hive.openBox('error-reporting-${boxCounter++}');
    await box.clear();
    addTearDown(box.close);
    final controller = DuckDownloadsController(
      api: _FailingApi(message),
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
    addTearDown(controller.dispose);
    // A host with no sign-in of its own, so the failure is reported rather
    // than turned into a sign-in prompt.
    await controller.extractUrl('https://example.com/watch/1');
    return controller;
  }

  group('a failure is described as what it was', () {
    test('a refusal by the server is not a broken internet connection', () async {
      // Exactly how Dio words a 403, URL and all. Every one of these used to
      // reach the user as "Connection problem. Check your internet and try
      // again." because the classifier ended with `contains('http')` — and a
      // Dio message always carries the request URL.
      final controller = await report(
        'DioException [bad response]: This exception was thrown because the '
        'response has a status code of 403 and RequestOptions.validateStatus '
        'was configured to throw for this status code. '
        'uri: https://rr3---sn-4g5e6nez.googlevideo.com/videoplayback?expire=1',
      );
      expect(controller.statusMessage.isKey('errorConnection'), isFalse);
      expect(controller.statusMessage.isKey('errorYouTubeBlocking'), isTrue);
    });

    test('rate limiting is reported as rate limiting', () async {
      final controller = await report(
        'DioException [bad response]: status code of 429. '
        'uri: https://www.googlevideo.com/videoplayback',
      );
      expect(controller.statusMessage.isKey('errorYouTubeBlocking'), isTrue);
    });

    test('a gone stream is not a broken connection', () async {
      final controller = await report(
        'DioException [bad response]: status code of 404. '
        'uri: https://rr1---sn-x.googlevideo.com/videoplayback',
      );
      expect(controller.statusMessage.isKey('errorConnection'), isFalse);
      expect(controller.statusMessage.isKey('errorUnsupportedLink'), isTrue);
    });

    test('an FFmpeg failure is not a broken connection', () async {
      final controller = await report(
        'FFmpeg video/audio merge failed: '
        '[mp4 @ 0x1] Could not find tag for codec vp9 in stream #0, '
        'codec not currently supported in container',
      );
      expect(controller.statusMessage.isKey('errorConnection'), isFalse);
    });

    test('a genuinely broken connection still says so', () async {
      final controller = await report(
        'SocketException: Failed host lookup: '
        "'rr3---sn-4g5e6nez.googlevideo.com' (OS Error: nodename nor servname "
        'provided, or not known, errno = 8)',
      );
      expect(controller.statusMessage.isKey('errorConnection'), isTrue);
    });

    test('a stalled stream still says so', () async {
      final controller = await report(
        'TimeoutException: The stream stopped sending data for 45s.',
      );
      expect(controller.statusMessage.isKey('errorConnection'), isTrue);
    });

    test('a bot check is a bot check', () async {
      final controller = await report(
        'Sign in to confirm you are not a bot',
      );
      expect(controller.statusMessage.isKey('errorYouTubeBlocking'), isTrue);
    });

    test('the word bot inside another word is not a bot check', () async {
      // `contains('bot')` matched "robots", among other things.
      final controller = await report(
        'Blocked by robots.txt on the origin server',
      );
      expect(controller.statusMessage.isKey('errorYouTubeBlocking'), isFalse);
    });

    test('an unrecognised failure keeps its own words', () async {
      // Better one English sentence the user can search for than a wrong
      // translated one.
      final controller = await report('The video has no downloadable streams.');
      expect(
        controller.statusMessage.english,
        contains('no downloadable streams'),
      );
    });
  });
}
