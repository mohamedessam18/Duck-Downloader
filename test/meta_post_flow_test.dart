import 'dart:io';

import 'package:duck_downloader/models/download_models.dart';
import 'package:duck_downloader/models/meta_post.dart';
import 'package:duck_downloader/services/api_client.dart';
import 'package:duck_downloader/services/clipboard_service.dart';
import 'package:duck_downloader/services/download_store.dart';
import 'package:duck_downloader/services/file_service.dart';
import 'package:duck_downloader/services/meta_post_service.dart';
import 'package:duck_downloader/services/platform_sessions.dart';
import 'package:duck_downloader/services/media_save_service.dart';
import 'package:duck_downloader/services/premium_manager.dart';
import 'package:duck_downloader/services/purchase_repository.dart';
import 'package:duck_downloader/services/subscription_service.dart';
import 'package:duck_downloader/state/downloads_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

const _postUrl = 'https://www.instagram.com/p/DHqXk_ZSAWk/';

MetaMedia _img(String url) =>
    MetaMedia(url: url, isVideo: false, width: 1440, height: 1800);

MetaMedia _vid(String url) => MetaMedia(
  url: url,
  isVideo: true,
  width: 1080,
  height: 1920,
  thumbnail: 'https://cdn/cover.jpg',
);

MetaPost _post(List<MetaMedia> items) =>
    MetaPost(shortcode: 'DHqXk_ZSAWk', title: 'A post', items: items);

/// The device tier, with whatever answer a test needs.
class _FakeMeta extends MetaPostService {
  _FakeMeta({this.post, this.error, String? pageBody})
    : super(pageReader: ((_) async => pageBody));

  final MetaPost? post;
  final Object? error;
  int calls = 0;

  @override
  Future<MetaPost> fetchPost(String url) async {
    calls++;
    if (post != null) return post!;
    throw error ?? const MetaPostUnavailable('nothing here');
  }
}

/// The backend tier.
class _FakeApi extends DuckApiClient {
  _FakeApi({this.playlist}) : super(apiBaseUrl: 'https://api.test');

  final PlaylistExtractResponse? playlist;
  int calls = 0;

  @override
  Future<PlaylistExtractResponse> extractPlaylist(String url) async {
    calls++;
    if (playlist != null) return playlist!;
    throw Exception('backend refused');
  }

  @override
  Future<MediaMetadata> extract(String url) async =>
      throw Exception('backend refused');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  var counter = 0;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('duck-instagram-flow');
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

  Future<DuckDownloadsController> build({
    required MetaPostService meta,
    DuckApiClient? api,
  }) async {
    final box = await Hive.openBox('instagram-flow-${counter++}');
    await box.clear();
    addTearDown(box.close);
    final controller = DuckDownloadsController(
      api: api ?? _FakeApi(),
      meta: meta,
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
    return controller;
  }

  group('post shapes reach the right screen', () {
    test('a single image is ready to download as an image', () async {
      final controller = await build(
        meta: _FakeMeta(post: _post([_img('https://cdn/1.jpg')])),
      );
      await controller.extractUrl(_postUrl);

      expect(controller.loginRequest, isNull);
      expect(controller.metadata, isNotNull);
      expect(controller.selectedType, DownloadType.image);
      // The direct CDN file, so the phone fetches it rather than asking the
      // server to fetch it on the phone's behalf.
      expect(controller.metadata!.url, 'https://cdn/1.jpg');
      expect(controller.flow, DuckFlow.ready);
    });

    test('a reel offers video, sound and its cover', () async {
      final controller = await build(
        meta: _FakeMeta(post: _post([_vid('https://cdn/reel.mp4')])),
      );
      await controller.extractUrl(_postUrl);

      expect(controller.selectedType, DownloadType.video);
      expect(controller.metadata!.url, 'https://cdn/reel.mp4');
      expect(controller.metadata!.qualities.single.label, '1920p');
      // Saving the sound is most of why people download Reels.
      expect(controller.metadata!.audioFormats, isNotEmpty);
      // And the Image chip on a video post means the cover frame.
      expect(controller.metadata!.thumbnail, 'https://cdn/cover.jpg');
    });

    test('a carousel of images becomes a batch of images', () async {
      final controller = await build(
        meta: _FakeMeta(
          post: _post([
            _img('https://cdn/1.jpg'),
            _img('https://cdn/2.jpg'),
            _img('https://cdn/3.jpg'),
          ]),
        ),
      );
      await controller.extractUrl(_postUrl);

      expect(controller.batchItems, hasLength(3));
      expect(controller.batchItems!.every((i) => !i.isVideo), isTrue);
      expect(controller.selectedType, DownloadType.image);
    });

    test('a carousel of videos becomes a batch of videos', () async {
      final controller = await build(
        meta: _FakeMeta(
          post: _post([_vid('https://cdn/1.mp4'), _vid('https://cdn/2.mp4')]),
        ),
      );
      await controller.extractUrl(_postUrl);

      expect(controller.batchItems, hasLength(2));
      expect(controller.batchItems!.every((i) => i.isVideo), isTrue);
      expect(controller.selectedType, DownloadType.video);
    });

    test('a mixed post keeps every item as what it is', () async {
      // The batch card opens on "everything as it is" when both kinds are
      // present, and that decision reads these flags.
      final controller = await build(
        meta: _FakeMeta(
          post: _post([
            _img('https://cdn/1.jpg'),
            _vid('https://cdn/2.mp4'),
            _img('https://cdn/3.jpg'),
            _vid('https://cdn/4.mp4'),
          ]),
        ),
      );
      await controller.extractUrl(_postUrl);

      expect(controller.batchItems, hasLength(4));
      expect(
        controller.batchItems!.map((i) => i.isVideo),
        [false, true, false, true],
      );
      expect(
        controller.batchItems!.map((i) => i.url),
        [
          'https://cdn/1.jpg',
          'https://cdn/2.mp4',
          'https://cdn/3.jpg',
          'https://cdn/4.mp4',
        ],
      );
    });
  });

  group('Threads takes the same road as Instagram', () {
    const threadsUrl = 'https://www.threads.com/@someone/post/C2QBoRaRmR1';

    test('a single image post', () async {
      final controller = await build(
        meta: _FakeMeta(post: _post([_img('https://cdn/t1.jpg')])),
      );
      await controller.extractUrl(threadsUrl);

      expect(controller.loginRequest, isNull);
      expect(controller.selectedType, DownloadType.image);
      expect(controller.metadata!.url, 'https://cdn/t1.jpg');
      // Filed under the platform it actually came from. The label used to be
      // hardcoded, so a Threads download appeared as an Instagram one.
      expect(controller.metadata!.platform, 'Threads');
    });

    test('a single video post', () async {
      // Threads has no Reels, but a post can still be one video — and that is
      // already the same shape, which is why there is no second code path.
      final controller = await build(
        meta: _FakeMeta(post: _post([_vid('https://cdn/t.mp4')])),
      );
      await controller.extractUrl(threadsUrl);

      expect(controller.selectedType, DownloadType.video);
      expect(controller.metadata!.url, 'https://cdn/t.mp4');
      expect(controller.metadata!.audioFormats, isNotEmpty);
      expect(controller.metadata!.platform, 'Threads');
    });

    test('several images', () async {
      final controller = await build(
        meta: _FakeMeta(
          post: _post([
            _img('https://cdn/t1.jpg'),
            _img('https://cdn/t2.jpg'),
            _img('https://cdn/t3.jpg'),
          ]),
        ),
      );
      await controller.extractUrl(threadsUrl);

      expect(controller.batchItems, hasLength(3));
      expect(controller.batchPlatform, 'Threads');
      expect(controller.selectedType, DownloadType.image);
    });

    test('several videos', () async {
      final controller = await build(
        meta: _FakeMeta(
          post: _post([_vid('https://cdn/t1.mp4'), _vid('https://cdn/t2.mp4')]),
        ),
      );
      await controller.extractUrl(threadsUrl);

      expect(controller.batchItems, hasLength(2));
      expect(controller.batchItems!.every((i) => i.isVideo), isTrue);
    });

    test('images and videos together keep their own kinds', () async {
      final controller = await build(
        meta: _FakeMeta(
          post: _post([
            _img('https://cdn/t1.jpg'),
            _vid('https://cdn/t2.mp4'),
            _img('https://cdn/t3.jpg'),
          ]),
        ),
      );
      await controller.extractUrl(threadsUrl);

      expect(controller.batchItems, hasLength(3));
      expect(
        controller.batchItems!.map((i) => i.isVideo),
        [false, true, false],
      );
    });

    test('a signed-out Threads post asks to sign in once', () async {
      final controller = await build(
        meta: _FakeMeta(error: const MetaAuthRequired('signed out')),
      );
      await controller.extractUrl(threadsUrl);

      expect(controller.loginRequest, isNotNull);
      expect(controller.loginRequest!.platform, SocialPlatform.threads);
      expect(controller.loginRequest!.retryUrl, threadsUrl);
    });

    test('a deleted Threads post is an error, not a sign-in prompt', () async {
      final controller = await build(
        meta: _FakeMeta(
          error: const MetaPostUnavailable('gone', isFinal: true),
        ),
      );
      await controller.extractUrl(threadsUrl);

      expect(controller.loginRequest, isNull);
      expect(controller.flow, DuckFlow.error);
    });
  });

  group('a tier that fails is not the end of the road', () {
    const threadsUrl = 'https://www.threads.com/@someone/post/C2QBoRaRmR1';

    test('a rejected request falls through to the backend', () async {
      // The bug: a 400 threw MetaPostUnavailable, and the controller stopped
      // on any MetaPostUnavailable at all — so one wrong header meant the two
      // working fallbacks were never asked, and the user was told the post
      // could not be opened when it could.
      final api = _FakeApi(
        playlist: const PlaylistExtractResponse(
          title: 'From the server',
          platform: 'Threads',
          items: [
            PlaylistItem(url: 'https://cdn/a.jpg', title: 'a', isVideo: false),
          ],
        ),
      );
      final controller = await build(
        meta: _FakeMeta(
          error: const MetaPostUnavailable('Threads would not open this (400)'),
        ),
        api: api,
      );
      await controller.extractUrl(threadsUrl);

      expect(api.calls, 1, reason: 'the backend must get its turn');
      expect(controller.metadata?.url, 'https://cdn/a.jpg');
      expect(controller.flow, DuckFlow.ready);
    });

    test('a rejected request reaches the page when the backend fails too',
        () async {
      const body = '{"items":[{"media_type":1,"image_versions2":{"candidates":'
          '[{"url":"https://cdn/page.jpg","width":1080,"height":1350}]}}]}';
      final controller = await build(
        meta: _FakeMeta(
          error: const MetaPostUnavailable('Threads would not open this (400)'),
          pageBody: body,
        ),
      );
      await controller.extractUrl(threadsUrl);

      expect(controller.metadata?.url, 'https://cdn/page.jpg');
    });

    test('a deleted post still stops immediately', () async {
      // Nothing can find a post that is gone, and trying costs two timeouts.
      final api = _FakeApi();
      final controller = await build(
        meta: _FakeMeta(
          error: const MetaPostUnavailable('gone', isFinal: true),
        ),
        api: api,
      );
      await controller.extractUrl(threadsUrl);

      expect(api.calls, 0);
      expect(controller.flow, DuckFlow.error);
      expect(controller.loginRequest, isNull);
    });

    test('a link with no post id in it stops immediately', () async {
      final api = _FakeApi();
      final controller = await build(
        meta: _FakeMeta(
          error: const MetaPostUnavailable('no post id', isFinal: true),
        ),
        api: api,
      );
      await controller.extractUrl('https://www.threads.com/@someone');

      expect(api.calls, 0);
      expect(controller.flow, DuckFlow.error);
    });
  });

  group('the sign-in is offered once, and only for a session problem', () {
    const threadsUrl = 'https://www.threads.com/@someone/post/C2QBoRaRmR1';
    const shareUrl = 'https://www.threads.com/share/BAT3nujVYV/';

    test('a share link that will not resolve never asks for a sign-in', () async {
      // Resolving happens in a browser holding whatever session the user has;
      // signing in again changes nothing about it, so offering to is the loop.
      final controller = await build(
        meta: _FakeMeta(
          error: const MetaPostUnavailable(
            'Could not open that share link. Open the post in the app and '
            'copy the post link instead.',
            isFinal: true,
          ),
        ),
      );
      await controller.extractUrl(shareUrl);

      expect(controller.loginRequest, isNull);
      expect(controller.flow, DuckFlow.error);
    });

    test('the page tier finding nothing never asks for a sign-in', () async {
      final controller = await build(
        meta: _FakeMeta(
          error: const MetaPostUnavailable('would not open it either'),
        ),
      );
      await controller.extractUrl(threadsUrl);

      expect(controller.loginRequest, isNull);
    });

    test('a signed-out user is asked once', () async {
      final controller = await build(
        meta: _FakeMeta(error: const MetaAuthRequired('signed out')),
      );
      await controller.extractUrl(threadsUrl);
      expect(controller.loginRequest, isNotNull);
    });

    test('the same link is not asked about twice in a row', () async {
      // What the user was doing by hand: paste, get asked, sign in, fail,
      // paste again, get asked again.
      final controller = await build(
        meta: _FakeMeta(error: const MetaAuthRequired('session refused')),
      );

      await controller.extractUrl(threadsUrl);
      expect(controller.loginRequest, isNotNull);
      controller.clearLoginRequest();

      // Coming back signed in and failing anyway means the session was never
      // the problem.
      await controller.completeLogin(
        LoginRequest(platform: SocialPlatform.threads, retryUrl: threadsUrl),
      );
      expect(controller.loginRequest, isNull);
      expect(controller.flow, DuckFlow.error);
    });

    test('a different link still gets its own chance', () async {
      final controller = await build(
        meta: _FakeMeta(error: const MetaAuthRequired('signed out')),
      );
      await controller.extractUrl(threadsUrl);
      expect(controller.loginRequest, isNotNull);
      controller.clearLoginRequest();

      await controller.extractUrl(
        'https://www.threads.com/@someone/post/DcvLupWjoWV',
      );
      expect(controller.loginRequest, isNotNull);
    });
  });

  group('the three tiers, in order', () {
    test('the device answers and nothing else is asked', () async {
      final api = _FakeApi();
      final meta = _FakeMeta(post: _post([_img('https://cdn/1.jpg')]));
      final controller = await build(meta: meta, api: api);
      await controller.extractUrl(_postUrl);

      expect(meta.calls, 1);
      expect(api.calls, 0, reason: 'the backend is a fallback, not a step');
    });

    test('the backend catches what the device could not', () async {
      final api = _FakeApi(
        playlist: const PlaylistExtractResponse(
          title: 'From the server',
          platform: 'Instagram',
          items: [
            PlaylistItem(url: 'https://cdn/a.jpg', title: 'a', isVideo: false),
            PlaylistItem(url: 'https://cdn/b.mp4', title: 'b', isVideo: true),
          ],
        ),
      );
      final controller = await build(
        meta: _FakeMeta(
          error: const MetaAuthRequired('signed out'),
        ),
        api: api,
      );
      await controller.extractUrl(_postUrl);

      expect(api.calls, 1);
      expect(controller.batchItems, hasLength(2));
      // A tier that succeeded is not a reason to ask for a sign-in.
      expect(controller.loginRequest, isNull);
    });

    test('the page is asked only after both of those fail', () async {
      const body = '''
        {"items":[{"media_type":1,"image_versions2":{"candidates":[
          {"url":"https://cdn/page.jpg","width":1080,"height":1350}]}}]}
      ''';
      final controller = await build(
        meta: _FakeMeta(
          error: const MetaAuthRequired('signed out'),
          pageBody: body,
        ),
      );
      await controller.extractUrl(_postUrl);

      expect(controller.metadata?.url, 'https://cdn/page.jpg');
      expect(controller.loginRequest, isNull);
    });
  });

  group('the sign-in loop', () {
    test('a signed-in user whose post loads is never asked to sign in', () async {
      // The report this exists for: signed in, and asked to sign in on every
      // attempt, forever.
      final controller = await build(
        meta: _FakeMeta(post: _post([_vid('https://cdn/1.mp4')])),
      );
      await controller.extractUrl(_postUrl);
      expect(controller.loginRequest, isNull);
      expect(controller.needsBrowserLogin, isFalse);
    });

    test('a missing session asks once, when nothing else worked', () async {
      final controller = await build(
        meta: _FakeMeta(
          error: const MetaAuthRequired('signed out'),
        ),
      );
      await controller.extractUrl(_postUrl);
      expect(controller.loginRequest, isNotNull);
      expect(controller.loginRequest!.retryUrl, _postUrl);
    });

    test('failing again straight after signing in does not ask again', () async {
      final controller = await build(
        meta: _FakeMeta(
          error: const MetaAuthRequired('signed out'),
        ),
      );
      await controller.extractUrl(_postUrl, afterSignIn: true);
      expect(controller.loginRequest, isNull);
      expect(controller.flow, DuckFlow.error);
    });

    test('a deleted post is an error, not a sign-in prompt', () async {
      // Signing in cannot bring a deleted post back, and offering it is how a
      // dead end turns into a loop.
      final api = _FakeApi();
      final controller = await build(
        meta: _FakeMeta(
          // Gone for good, which is the only kind that stops the other tiers.
          error: const MetaPostUnavailable(
            'This Instagram post no longer exists.',
            isFinal: true,
          ),
        ),
        api: api,
      );
      await controller.extractUrl(_postUrl);

      expect(controller.loginRequest, isNull);
      expect(controller.flow, DuckFlow.error);
      // And nothing else is troubled for a post Instagram says is gone.
      expect(api.calls, 0);
    });
  });
}
