import 'dart:async';
import 'dart:io';

import 'package:duck_downloader/models/browser_image_candidate.dart';
import 'package:duck_downloader/models/download_models.dart';
import 'package:duck_downloader/services/api_client.dart';
import 'package:duck_downloader/services/clipboard_service.dart';
import 'package:duck_downloader/services/download_store.dart';
import 'package:duck_downloader/services/file_service.dart';
import 'package:duck_downloader/services/premium_manager.dart';
import 'package:duck_downloader/services/purchase_repository.dart';
import 'package:duck_downloader/services/subscription_service.dart';
import 'package:duck_downloader/services/media_save_service.dart';
import 'package:duck_downloader/state/downloads_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class FakeMediaSaveService extends MediaSaveService {
  FakeMediaSaveService({this.fail = false});

  final bool fail;
  int videoCalls = 0;
  int audioCalls = 0;

  @override
  Future<ExternalSaveResult> saveVideo({
    required String path,
    required String filename,
  }) async {
    videoCalls++;
    if (fail) throw Exception('Gallery permission denied.');
    return const ExternalSaveResult(success: true, uri: 'content://video');
  }

  @override
  Future<ExternalSaveResult> saveAudio({
    required String path,
    required String filename,
    required DownloadType type,
  }) async {
    audioCalls++;
    if (fail) throw Exception('Music save failed.');
    return const ExternalSaveResult(success: true, uri: 'content://audio');
  }
}

class FakeBatchApiClient extends DuckApiClient {
  FakeBatchApiClient({this.failUrls = const {}})
    : super(apiBaseUrl: 'https://api.test');

  final Set<String> failUrls;
  final List<String> startedUrls = [];
  final List<({String url, DownloadType type})> startedDownloads = [];

  @override
  Future<String> startDownload({
    required String url,
    required DownloadType type,
    required String quality,
    bool removeMusic = false,
    bool premiumNoWatermark = false,
  }) async {
    if (failUrls.contains(url)) throw Exception('Start failed');
    startedUrls.add(url);
    startedDownloads.add((url: url, type: type));
    return 'download-${startedUrls.length}';
  }

  @override
  Stream<DownloadStatusUpdate> watchDownload(String id) => const Stream.empty();
}

class FakeLockedBrowserApiClient extends DuckApiClient {
  FakeLockedBrowserApiClient() : super(apiBaseUrl: 'https://api.test');

  @override
  Future<PlaylistExtractResponse> extractPlaylist(String url) async {
    throw Exception(
      'Could not access the full-size Instagram image. This post may require login or cookies.',
    );
  }
}

class FakeFileService extends DuckFileService {
  @override
  Future<String> moveFileToVault({
    required String currentPath,
    required String filename,
  }) async {
    return '/vault/$filename';
  }

  @override
  @override
  Future<String> copyFileToVault({
    required String currentPath,
    required String filename,
  }) async {
    return '/vault/$filename';
  }

  Future<String> moveFileFromVault({
    required String currentPath,
    required String filename,
    required DownloadType type,
  }) async {
    return '/library/$filename';
  }

  @override
  Future<String> getDecryptedTempPath({
    required String vaultPath,
    required String originalFilename,
  }) async {
    return '/temp/$originalFilename';
  }

  @override
  Future<void> updateMp3Metadata({
    required String filePath,
    required String title,
    required String artist,
    required String album,
  }) async {}
}

void main() {
  late Directory hiveDir;
  late File mediaFile;
  final secureStorage = <String, String>{};

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final key = call.arguments['key'] as String?;
            switch (call.method) {
              case 'read':
                return key == null ? null : secureStorage[key];
              case 'write':
                if (key != null) {
                  secureStorage[key] = call.arguments['value'] as String;
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getApplicationDocumentsDirectory') {
              return hiveDir.path;
            }
            return null;
          },
        );
    hiveDir = await Directory.systemTemp.createTemp('media_save_controller_');
    Hive.init(hiveDir.path);
    mediaFile = File('${hiveDir.path}/video.mp4');
    await mediaFile.writeAsBytes([1, 2, 3]);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  test('manual video save marks completed item as saved to gallery', () async {
    final box = await Hive.openBox('media-save-controller-success');
    addTearDown(box.close);
    await box.clear();
    final saver = FakeMediaSaveService();
    final controller = _controller(box, saver);
    addTearDown(controller.dispose);
    final item = _item(filePath: mediaFile.path);

    await controller.saveVideoExternally(item);

    expect(saver.videoCalls, 1);
    expect(controller.downloads.single.savedToGallery, isTrue);
    expect(controller.downloads.single.status, DownloadStatus.completed);
  });

  test(
    'manual video save failure keeps item completed with visible error',
    () async {
      final box = await Hive.openBox('media-save-controller-failure');
      addTearDown(box.close);
      await box.clear();
      final saver = FakeMediaSaveService(fail: true);
      final controller = _controller(box, saver);
      addTearDown(controller.dispose);
      final item = _item(filePath: mediaFile.path);

      await controller.saveVideoExternally(item);

      expect(controller.downloads.single.status, DownloadStatus.completed);
      expect(
        controller.downloads.single.externalSaveError,
        contains('Gallery'),
      );
      expect(controller.status, contains('Gallery'));
    },
  );

  test('manual audio save marks completed item as saved to music', () async {
    final box = await Hive.openBox('media-save-controller-audio-success');
    addTearDown(box.close);
    await box.clear();
    final saver = FakeMediaSaveService();
    final controller = _controller(box, saver);
    addTearDown(controller.dispose);
    final item = _item(
      filePath: mediaFile.path,
    ).copyWith(type: DownloadType.audio);

    await controller.saveAudioExternally(item);

    expect(saver.audioCalls, 1);
    expect(controller.downloads.single.savedToMusic, isTrue);
    expect(controller.downloads.single.status, DownloadStatus.completed);
  });

  test(
    'manual audio save failure keeps item completed with visible error',
    () async {
      final box = await Hive.openBox('media-save-controller-audio-failure');
      addTearDown(box.close);
      await box.clear();
      final saver = FakeMediaSaveService(fail: true);
      final controller = _controller(box, saver);
      addTearDown(controller.dispose);
      final item = _item(
        filePath: mediaFile.path,
      ).copyWith(type: DownloadType.audio);

      await controller.saveAudioExternally(item);

      expect(controller.downloads.single.status, DownloadStatus.completed);
      expect(controller.downloads.single.externalSaveError, contains('Music'));
      expect(controller.status, contains('Music'));
    },
  );

  test('toggleFavorite toggles favorite field on item', () async {
    final box = await Hive.openBox('media-save-controller-favorite');
    addTearDown(box.close);
    await box.clear();
    final item = _item(filePath: mediaFile.path);
    await box.put('downloads', [item.toJson()]);
    final controller = _controller(box, FakeMediaSaveService());
    addTearDown(controller.dispose);

    expect(controller.downloads.single.favorite, isFalse);

    await controller.toggleFavorite(controller.downloads.single);
    expect(controller.downloads.single.favorite, isTrue);

    await controller.toggleFavorite(controller.downloads.single);
    expect(controller.downloads.single.favorite, isFalse);
  });

  test('playlists CRUD operations save correctly', () async {
    final box = await Hive.openBox('media-save-controller-playlists');
    addTearDown(box.close);
    await box.clear();
    final controller = _controller(box, FakeMediaSaveService());
    addTearDown(controller.dispose);

    expect(controller.playlists, isEmpty);

    await controller.createPlaylist('Favorites Video Mix');
    expect(controller.playlists.length, 1);
    expect(controller.playlists.single.name, 'Favorites Video Mix');
    expect(controller.playlists.single.downloadIds, isEmpty);

    final playlistId = controller.playlists.single.id;

    await controller.addDownloadToPlaylist(playlistId, 'video-1');
    expect(controller.playlists.single.downloadIds, ['video-1']);

    await controller.removeDownloadFromPlaylist(playlistId, 'video-1');
    expect(controller.playlists.single.downloadIds, isEmpty);

    await controller.deletePlaylist(playlistId);
    expect(controller.playlists, isEmpty);
  });

  test('vault passcode setup, lock/unlock, and move operations work', () async {
    final box = await Hive.openBox('media-save-controller-vault');
    addTearDown(box.close);
    await box.clear();
    final controller = _controller(box, FakeMediaSaveService());
    addTearDown(controller.dispose);

    expect(controller.isVaultSetup, isFalse);
    expect(controller.isVaultLocked, isTrue);

    await controller.setVaultPin('5555');
    expect(controller.isVaultSetup, isTrue);

    bool ok = await controller.checkVaultPin('1111');
    expect(ok, isFalse);
    expect(controller.isVaultLocked, isTrue);

    ok = await controller.checkVaultPin('5555');
    expect(ok, isTrue);
    expect(controller.isVaultLocked, isFalse);

    controller.lockVault();
    expect(controller.isVaultLocked, isTrue);
  });

  test(
    'moveItemToVault and moveItemFromVault updates filePath and isPrivate',
    () async {
      final box = await Hive.openBox('media-save-controller-vault-move');
      addTearDown(box.close);
      await box.clear();
      final item = _item(filePath: mediaFile.path);
      await box.put('downloads', [item.toJson()]);
      final controller = _controller(box, FakeMediaSaveService());
      addTearDown(controller.dispose);

      expect(controller.downloads.single.isPrivate, isFalse);

      await controller.setVaultPin('5555');

      await controller.moveItemToVault(controller.downloads.single);
      expect(controller.downloads.single.isPrivate, isTrue);
      expect(controller.downloads.single.filePath, contains('/vault/'));

      await controller.moveItemFromVault(controller.downloads.single);
      expect(controller.downloads.single.isPrivate, isFalse);
      expect(controller.downloads.single.filePath, contains('/library/'));
    },
  );

  test('updateItemMetadata updates fields in store and controller', () async {
    final box = await Hive.openBox('media-save-controller-metadata');
    addTearDown(box.close);
    await box.clear();
    final item = _item(
      filePath: mediaFile.path,
    ).copyWith(type: DownloadType.audio);
    await box.put('downloads', [item.toJson()]);
    final controller = _controller(box, FakeMediaSaveService());
    addTearDown(controller.dispose);

    expect(controller.downloads.single.title, 'Video');
    expect(controller.downloads.single.artist, isNull);
    expect(controller.downloads.single.album, isNull);

    await controller.updateItemMetadata(
      controller.downloads.single,
      title: 'New Title',
      artist: 'New Artist',
      album: 'New Album',
    );

    final updated = controller.downloads.single;
    expect(updated.title, 'New Title');
    expect(updated.artist, 'New Artist');
    expect(updated.album, 'New Album');
  });

  test(
    'batch image download starts a separate item for each carousel image',
    () async {
      final box = await Hive.openBox('media-save-controller-image-batch');
      addTearDown(box.close);
      await box.clear();
      final api = FakeBatchApiClient();
      final controller = _controller(box, FakeMediaSaveService(), api: api);
      addTearDown(controller.dispose);
      controller.batchPlatform = 'Instagram';
      controller.batchItems = const [
        PlaylistItem(
          url: 'https://cdninstagram.com/full-1.jpg',
          title: 'Image 1',
          thumbnail: 'https://cdninstagram.com/full-1.jpg',
        ),
        PlaylistItem(
          url: 'https://cdninstagram.com/full-2.jpg',
          title: 'Image 2',
          thumbnail: 'https://cdninstagram.com/full-2.jpg',
        ),
      ];

      await controller.startBatchDownload(
        urls: controller.batchItems!.map((item) => item.url).toList(),
        type: DownloadType.image,
        quality: 'Best',
      );

      expect(api.startedUrls, [
        'https://cdninstagram.com/full-1.jpg',
        'https://cdninstagram.com/full-2.jpg',
      ]);
      final downloads = controller.downloads.toList()
        ..sort((a, b) => a.title.compareTo(b.title));
      expect(downloads.length, 2);
      expect(downloads.map((item) => item.title), ['Image 1', 'Image 2']);
      expect(downloads.map((item) => item.thumbnail), [
        'https://cdninstagram.com/full-1.jpg',
        'https://cdninstagram.com/full-2.jpg',
      ]);
      expect(
        downloads.every((item) => item.type == DownloadType.image),
        isTrue,
      );
      expect(controller.status, 'Started 2 images');
    },
  );

  test('batch image download reports partial start failures', () async {
    final box = await Hive.openBox('media-save-controller-image-batch-failure');
    addTearDown(box.close);
    await box.clear();
    final api = FakeBatchApiClient(
      failUrls: {'https://cdninstagram.com/full-2.jpg'},
    );
    final controller = _controller(box, FakeMediaSaveService(), api: api);
    addTearDown(controller.dispose);
    controller.batchPlatform = 'Instagram';
    controller.batchItems = const [
      PlaylistItem(
        url: 'https://cdninstagram.com/full-1.jpg',
        title: 'Image 1',
      ),
      PlaylistItem(
        url: 'https://cdninstagram.com/full-2.jpg',
        title: 'Image 2',
      ),
    ];

    await controller.startBatchDownload(
      urls: controller.batchItems!.map((item) => item.url).toList(),
      type: DownloadType.image,
      quality: 'Best',
    );

    expect(api.startedUrls, ['https://cdninstagram.com/full-1.jpg']);
    expect(
      controller.downloads.single.url,
      'https://cdninstagram.com/full-1.jpg',
    );
    expect(controller.status, 'Started 1 images, 1 failed');
  });

  test(
    'batch hybrid download downloads images as images and videos as videos',
    () async {
      final box = await Hive.openBox('media-save-controller-hybrid-batch');
      addTearDown(box.close);
      await box.clear();
      final api = FakeBatchApiClient();
      final controller = _controller(box, FakeMediaSaveService(), api: api);
      addTearDown(controller.dispose);
      controller.batchPlatform = 'Instagram';
      controller.batchItems = const [
        PlaylistItem(
          url: 'https://cdninstagram.com/image-1.jpg',
          title: 'Image 1',
          thumbnail: 'https://cdninstagram.com/image-1.jpg',
          isVideo: false,
        ),
        PlaylistItem(
          url: 'https://cdninstagram.com/video-1.mp4',
          title: 'Video 1',
          thumbnail: 'https://cdninstagram.com/video-1.mp4',
          isVideo: true,
        ),
      ];

      await controller.startBatchDownload(
        urls: controller.batchItems!.map((item) => item.url).toList(),
        type: DownloadType.video,
        quality: 'Best',
        forceHybrid: true,
      );

      expect(api.startedDownloads, hasLength(2));
      expect(
        api.startedDownloads[0].url,
        'https://cdninstagram.com/image-1.jpg',
      );
      expect(api.startedDownloads[0].type, DownloadType.image);
      expect(
        api.startedDownloads[1].url,
        'https://cdninstagram.com/video-1.mp4',
      );
      expect(api.startedDownloads[1].type, DownloadType.video);
    },
  );

  test('batch image download rejects preview-only Instagram items', () async {
    final box = await Hive.openBox('media-save-controller-image-preview-only');
    addTearDown(box.close);
    await box.clear();
    final api = FakeBatchApiClient();
    final controller = _controller(box, FakeMediaSaveService(), api: api);
    addTearDown(controller.dispose);
    controller.batchPlatform = 'Instagram';
    controller.batchItems = const [
      PlaylistItem(
        url: 'https://instagram.com/preview-square.jpg',
        title: 'Preview Image',
        thumbnail: 'https://instagram.com/preview-square.jpg',
        width: 615,
        height: 614,
        source: 'instagram_og_image',
        isPreview: true,
      ),
    ];

    await controller.startBatchDownload(
      urls: controller.batchItems!.map((item) => item.url).toList(),
      type: DownloadType.image,
      quality: 'Best',
    );

    expect(api.startedUrls, isEmpty);
    expect(controller.downloads, isEmpty);
    expect(controller.status, 'Failed to start 1 images');
    expect(controller.flow, DuckFlow.error);
  });

  test(
    'full-size Instagram failure requests locked browser fallback',
    () async {
      final box = await Hive.openBox('media-save-controller-locked-browser');
      addTearDown(box.close);
      await box.clear();
      final controller = _controller(
        box,
        FakeMediaSaveService(),
        api: FakeLockedBrowserApiClient(),
      );
      addTearDown(controller.dispose);

      controller.detectedClipboardUrl =
          'https://www.instagram.com/p/DZtZmxknHtG/';
      await controller.acceptClipboardDetection();

      expect(controller.lockedBrowserRequest, isNotNull);
      expect(controller.lockedBrowserRequest!.platform, 'Instagram');
      expect(controller.flow, DuckFlow.ready);
      expect(controller.status, contains('Duck Downloader browser'));
    },
  );

  test(
    'browser image candidates start downloads from candidate urls',
    () async {
      final box = await Hive.openBox('media-save-controller-browser-images');
      addTearDown(box.close);
      await box.clear();
      final api = FakeBatchApiClient();
      final controller = _controller(box, FakeMediaSaveService(), api: api);
      addTearDown(controller.dispose);

      await controller.startBrowserImageDownloads(
        platform: 'Instagram',
        candidates: const [
          BrowserImageCandidate(
            url: 'https://scontent.cdninstagram.com/full-1.jpg',
            width: 853,
            height: 1280,
            source: 'img_srcset',
          ),
          BrowserImageCandidate(
            url: 'https://instagram.com/preview.jpg',
            width: 615,
            height: 614,
            source: 'meta_preview',
            isPreview: true,
          ),
        ],
      );

      expect(api.startedUrls, ['https://scontent.cdninstagram.com/full-1.jpg']);
      expect(controller.downloads.single.url, api.startedUrls.single);
      expect(controller.downloads.single.thumbnail, api.startedUrls.single);
      expect(controller.downloads.single.platform, 'Instagram');
    },
  );

  test('browser carousel candidates become ordered image downloads', () async {
    final box = await Hive.openBox('media-save-controller-browser-carousel');
    addTearDown(box.close);
    await box.clear();
    final api = FakeBatchApiClient();
    final controller = _controller(box, FakeMediaSaveService(), api: api);
    addTearDown(controller.dispose);

    await controller.startBrowserImageDownloads(
      platform: 'Instagram',
      candidates: List.generate(
        10,
        (index) => BrowserImageCandidate(
          url: 'https://scontent.cdninstagram.com/full-$index.jpg',
          width: 853,
          height: 1280,
          source: 'img_srcset',
          order: index,
          slideIndex: index,
        ),
      ),
    );

    expect(controller.flow, DuckFlow.ready);
    expect(controller.batchItems, hasLength(10));
    expect(api.startedUrls, isEmpty);

    final urls = controller.batchItems!.map((item) => item.url).toList();
    await controller.startBatchDownload(
      urls: urls,
      type: DownloadType.image,
      quality: 'Best',
    );

    expect(api.startedUrls, [
      'https://scontent.cdninstagram.com/full-0.jpg',
      'https://scontent.cdninstagram.com/full-1.jpg',
      'https://scontent.cdninstagram.com/full-2.jpg',
      'https://scontent.cdninstagram.com/full-3.jpg',
      'https://scontent.cdninstagram.com/full-4.jpg',
      'https://scontent.cdninstagram.com/full-5.jpg',
      'https://scontent.cdninstagram.com/full-6.jpg',
      'https://scontent.cdninstagram.com/full-7.jpg',
      'https://scontent.cdninstagram.com/full-8.jpg',
      'https://scontent.cdninstagram.com/full-9.jpg',
    ]);
    expect(controller.downloads.length, 10);
    expect(controller.downloads.map((item) => item.title).toSet(), {
      'Image 1',
      'Image 2',
      'Image 3',
      'Image 4',
      'Image 5',
      'Image 6',
      'Image 7',
      'Image 8',
      'Image 9',
      'Image 10',
    });
  });
  test('file service updateMp3Metadata writes ID3v1 tag to file', () async {
    final file = File('${hiveDir.path}/test_metadata.mp3');
    await file.writeAsBytes(List<int>.filled(500, 0));

    final fileService = DuckFileService();
    await fileService.updateMp3Metadata(
      filePath: file.path,
      title: 'Song Title',
      artist: 'Song Artist',
      album: 'Song Album',
    );

    final bytes = await file.readAsBytes();
    expect(bytes.length, 500 + 128);
    expect(String.fromCharCodes(bytes.sublist(500, 503)), 'TAG');
    expect(
      String.fromCharCodes(
        bytes.sublist(503, 533),
      ).replaceAll(RegExp(r'\x00'), '').trim(),
      'Song Title',
    );
    expect(
      String.fromCharCodes(
        bytes.sublist(533, 563),
      ).replaceAll(RegExp(r'\x00'), '').trim(),
      'Song Artist',
    );
    expect(
      String.fromCharCodes(
        bytes.sublist(563, 593),
      ).replaceAll(RegExp(r'\x00'), '').trim(),
      'Song Album',
    );
  });
}

DuckDownloadsController _controller(
  Box box,
  MediaSaveService saver, {
  DuckApiClient? api,
}) {
  return DuckDownloadsController(
    api: api ?? DuckApiClient(),
    clipboard: DuckClipboardService(),
    files: FakeFileService(),
    mediaSaver: saver,
    store: DownloadStore(box),
    premiumManager: PremiumManager(
      subscriptions: SubscriptionService(),
      purchases: PurchaseRepository(box),
    ),
    initializePremium: false,
    initializePlatformServices: false,
  );
}

DownloadItem _item({required String filePath}) {
  return DownloadItem(
    id: 'video-1',
    url: 'https://example.com/video',
    title: 'Video',
    platform: 'Example',
    type: DownloadType.video,
    filePath: filePath,
    createdAt: DateTime.utc(2026),
    status: DownloadStatus.completed,
    progress: 100,
    favorite: false,
  );
}
