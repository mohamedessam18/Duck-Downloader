import 'package:duck_downloader/models/download_models.dart';
import 'package:just_audio/just_audio.dart';
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

  group('the two players share one volume', () {
    test('closing a video hands the player back audible', () async {
      // The reported bug, in three steps. Watching a video mutes this player
      // on purpose — the video's own track is the sound — and closing the
      // video used to stop it without undoing that. The next song then played
      // perfectly and silently, which reads as audio being broken after you
      // watch a video.
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.audioPlayer.setVolume(0.0);
      expect(controller.audioPlayer.volume, 0.0);

      await controller.stopBackgroundVideoAudio();

      expect(controller.audioPlayer.volume, 1.0);
    });

    test('it is safe to close a video twice', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.stopBackgroundVideoAudio();
      await controller.stopBackgroundVideoAudio();

      expect(controller.audioPlayer.volume, 1.0);
    });
  });

  group('an interruption reaches the video too', () {
    test('a registered handler is called, and only while registered', () async {
      // Unplugging headphones does not change the app lifecycle, so nothing
      // was telling the video to stop — it carried on out loud through the
      // phone's speaker, which is the one thing this event exists to prevent.
      final controller = createController();
      addTearDown(controller.dispose);

      var pauses = 0;
      void handler() => pauses++;

      controller.addPausePlaybackHandler(handler);
      controller.debugRequestPauseEverything();
      expect(pauses, 1);

      controller.removePausePlaybackHandler(handler);
      controller.debugRequestPauseEverything();
      expect(pauses, 1);
    });

    test('one handler throwing does not silence the others', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      var reached = false;
      controller.addPausePlaybackHandler(() => throw StateError('disposed'));
      controller.addPausePlaybackHandler(() => reached = true);

      controller.debugRequestPauseEverything();
      expect(reached, isTrue);
    });
  });

  test('repeat-all is not handed to the player as repeat-all', () async {
    final controller = createController();
    addTearDown(controller.dispose);

    // off -> all
    await controller.toggleLoopMode();
    expect(controller.loopMode, LoopMode.all);
    // The player drives one file at a time, so LoopMode.all there would loop
    // that file and the track would never end — which is exactly how
    // "repeat all" used to behave like "repeat one".
    expect(controller.audioPlayer.loopMode, LoopMode.off);

    // all -> one, the only mode the player itself should handle
    await controller.toggleLoopMode();
    expect(controller.loopMode, LoopMode.one);
    expect(controller.audioPlayer.loopMode, LoopMode.one);

    // one -> off
    await controller.toggleLoopMode();
    expect(controller.loopMode, LoopMode.off);
    expect(controller.audioPlayer.loopMode, LoopMode.off);
  });

  test('shuffle and repeat survive a restart', () async {
    final first = createController();
    await first.toggleShuffle();
    await first.toggleLoopMode();
    expect(first.shuffleEnabled, isTrue);
    expect(first.loopMode, LoopMode.all);
    first.dispose();

    // Same storage, new controller — what a relaunch actually looks like.
    final second = createController();
    addTearDown(second.dispose);
    expect(second.shuffleEnabled, isTrue);
    expect(second.loopMode, LoopMode.all);
  });

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
