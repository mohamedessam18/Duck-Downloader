import 'dart:io';

import 'package:duck_downloader/models/download_models.dart';
import 'package:duck_downloader/services/api_client.dart';
import 'package:duck_downloader/services/clipboard_service.dart';
import 'package:duck_downloader/services/download_store.dart';
import 'package:duck_downloader/services/file_service.dart';
import 'package:duck_downloader/services/media_save_service.dart';
import 'package:duck_downloader/models/instagram_post.dart';
import 'package:duck_downloader/services/instagram_service.dart';
import 'package:duck_downloader/services/platform_sessions.dart';
import 'package:duck_downloader/services/youtube_explode_service.dart';
import 'package:duck_downloader/services/premium_manager.dart';
import 'package:duck_downloader/services/purchase_repository.dart';
import 'package:duck_downloader/services/subscription_service.dart';
import 'package:duck_downloader/state/downloads_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// Fails the way a site does when it wants a login.
class _NeedsLoginApi extends DuckApiClient {
  _NeedsLoginApi() : super(apiBaseUrl: 'https://api.test');

  @override
  Future<MediaMetadata> extract(String url) async {
    throw Exception('This post requires login or cookies.');
  }

  @override
  Future<PlaylistExtractResponse> extractPlaylist(String url) async {
    throw Exception('This post requires login or cookies.');
  }
}

/// Fails for a reason no sign-in can fix.
class _BrokenLinkApi extends DuckApiClient {
  _BrokenLinkApi() : super(apiBaseUrl: 'https://api.test');

  @override
  Future<MediaMetadata> extract(String url) async {
    throw Exception('Unsupported URL: nothing to download here.');
  }

  @override
  Future<PlaylistExtractResponse> extractPlaylist(String url) async {
    throw Exception('Unsupported URL: nothing to download here.');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('duck-login-flow');
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

  Future<DuckDownloadsController> build(
    String name, {
    DuckApiClient? api,
    YouTubeExplodeService? ytExplode,
  }) async {
    final box = await Hive.openBox(name);
    await box.clear();
    addTearDown(box.close);
    final controller = DuckDownloadsController(
      api: api ?? DuckApiClient(apiBaseUrl: 'https://api.test'),
      instagram: _SignedOutInstagram(),
      ytExplode: ytExplode,
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

  test('asking to sign in tells anyone listening', () async {
    // The bug this exists for: the home screen's button assigned the request
    // straight onto a public field, so no notification was sent, the
    // AnimatedBuilder around the screen never rebuilt, and pressing the button
    // did nothing at all until something unrelated happened to notify.
    final controller = await build('login-flow-notifies', api: _NeedsLoginApi());
    var notifications = 0;
    controller.addListener(() => notifications++);

    await controller.extractUrl('https://www.instagram.com/p/ABC/');
    expect(controller.loginRequest, isNotNull);

    controller.clearLoginRequest();
    expect(controller.loginRequest, isNull);

    final before = notifications;
    controller.openLoginForLastAttempt();
    expect(controller.loginRequest, isNotNull);
    expect(
      notifications,
      greaterThan(before),
      reason: 'reopening the sign-in must notify, or nothing rebuilds',
    );
  });

  test('the sign-in carries the link that needed it', () async {
    final controller = await build('login-flow-carries', api: _NeedsLoginApi());
    await controller.extractUrl('https://www.instagram.com/p/ABC/');

    expect(controller.loginRequest!.platform, SocialPlatform.instagram);
    expect(
      controller.loginRequest!.retryUrl,
      'https://www.instagram.com/p/ABC/',
    );
    // Backing out of the sign-in used to be a dead end: the status the app set
    // when it opened the browser was not one the button looked for, so there
    // was no way back other than pasting the link again.
    controller.clearLoginRequest();
    expect(controller.needsBrowserLogin, isTrue);
  });

  test('a YouTube failure the app itself worded does not ask for a sign-in',
      () async {
    // The Shorts loop. `/shorts/<id>?feature=share` did not parse, so the app
    // threw its own "may be private, age-restricted, or unavailable" — and the
    // sign-in heuristic matched "age-restricted" in that very sentence.
    // Signing in changed nothing, so the prompt came straight back.
    final controller = await build(
      'login-flow-youtube-unreadable',
      ytExplode: _UnreadableYouTube(),
    );
    await controller.extractUrl(
      'https://www.youtube.com/shorts/dQw4w9WgXcQ?feature=share',
    );

    expect(controller.loginRequest, isNull);
    expect(controller.flow, DuckFlow.error);
  });

  test('a real YouTube bot check still asks for a sign-in', () async {
    final controller = await build(
      'login-flow-youtube-botcheck',
      ytExplode: _BotCheckedYouTube(),
    );
    await controller.extractUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ');

    expect(controller.loginRequest, isNotNull);
    expect(controller.loginRequest!.platform, SocialPlatform.youtube);
  });

  test('reopening without a previous attempt does nothing', () async {
    final controller = await build('login-flow-empty');
    controller.openLoginForLastAttempt();
    expect(controller.loginRequest, isNull);
  });

  test('a site Duck cannot sign into reports the real error', () async {
    // Offering a sign-in here would be a button that cannot possibly work.
    final controller = await build('login-flow-unknown', api: _BrokenLinkApi());
    await controller.extractUrl('https://example.com/video/1');

    expect(controller.loginRequest, isNull);
    expect(controller.needsBrowserLogin, isFalse);
    expect(controller.flow, DuckFlow.error);
  });

  test('a YouTube failure a sign-in cannot fix does not ask for one', () async {
    final controller = await build('login-flow-youtube', api: _BrokenLinkApi());
    await controller.extractUrl('https://example.com/not-youtube');
    expect(controller.loginRequest, isNull);
  });

  test('failing again after signing in stops asking', () async {
    // Otherwise: fail, sign in, fail, sign in, forever.
    final controller = await build('login-flow-loop', api: _NeedsLoginApi());
    await controller.extractUrl(
      'https://www.instagram.com/p/ABC/',
      afterSignIn: true,
    );

    expect(controller.loginRequest, isNull);
    expect(controller.flow, DuckFlow.error);
  });
}

/// Instagram, signed out. Every tier refuses for want of a session.
class _SignedOutInstagram extends InstagramService {
  _SignedOutInstagram()
    : super(pageReader: (_, _) async => null);

  @override
  Future<InstagramPost> fetchPost(String url) async =>
      throw const InstagramAuthRequired(
        'Instagram needs you to be signed in to open this post.',
      );
}

/// YouTube, failing the way a video Duck could not identify fails.
class _UnreadableYouTube extends YouTubeExplodeService {
  @override
  Future<MediaMetadata?> extractMetadata(String url) async => null;
}

/// YouTube, failing the way a bot check fails.
class _BotCheckedYouTube extends YouTubeExplodeService {
  @override
  Future<MediaMetadata?> extractMetadata(String url) async =>
      throw Exception('Sign in to confirm you are not a bot');
}
