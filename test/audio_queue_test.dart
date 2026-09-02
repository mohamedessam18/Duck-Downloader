import 'package:duck_downloader/models/download_models.dart';
import 'package:audio_session/audio_session.dart';
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
import 'package:duck_downloader/state/playback_session.dart';
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

  group('acting on several files at once', () {
    DownloadItem file(String id) => DownloadItem(
      id: id,
      url: 'https://example.com/$id',
      title: id,
      platform: 'Example',
      type: DownloadType.video,
      filePath: '/tmp/$id.mp4',
      createdAt: DateTime.utc(2026),
      status: DownloadStatus.completed,
      progress: 100,
      favorite: false,
    );

    test('deleting several leaves none of them behind', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      for (final id in ['a', 'b', 'c']) {
        await controller.debugPutDownload(file(id));
      }

      await controller.deleteMany(
        controller.videos.where((item) => item.id != 'b'),
      );

      expect(controller.videos.map((e) => e.id), ['b']);
      expect(controller.trashedItems.map((e) => e.id).toSet(), {'a', 'c'});
    });

    test('one tap has one outcome, not a flip each', () async {
      // Half favourited and half not: making them all favourites is what the
      // user asked for. Toggling each row would leave the set exactly as
      // mixed as it started.
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.debugPutDownload(file('a'));
      await controller.debugPutDownload(file('b').copyWith(favorite: true));

      await controller.favoriteMany(controller.videos, true);

      expect(controller.videos.every((item) => item.favorite), isTrue);
    });

    test('and it can take them all back off', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.debugPutDownload(file('a').copyWith(favorite: true));
      await controller.debugPutDownload(file('b').copyWith(favorite: true));

      await controller.favoriteMany(controller.videos, false);

      expect(controller.videos.any((item) => item.favorite), isFalse);
    });

    test('an empty selection does nothing at all', () async {
      final controller = createController();
      addTearDown(controller.dispose);
      await controller.debugPutDownload(file('a'));

      await controller.deleteMany(const []);
      await controller.favoriteMany(const [], true);

      expect(controller.videos, hasLength(1));
      expect(controller.trashedItems, isEmpty);
    });
  });

  group('deleting actually removes it from the library', () {
    DownloadItem file(String id, {String path = ''}) => DownloadItem(
      id: id,
      url: 'https://example.com/$id',
      title: id,
      platform: 'Example',
      type: DownloadType.video,
      filePath: path.isEmpty ? '/tmp/$id.mp4' : path,
      createdAt: DateTime.utc(2026),
      status: DownloadStatus.completed,
      progress: 100,
      favorite: false,
    );

    test('a deleted file leaves the list and lands in the trash', () async {
      // The report: deleting appeared to do nothing. The store merged updates
      // from a hand-written list of fields, `deletedAt` was not on it, so the
      // flag was written and immediately dropped — the row came back
      // undeleted and the file stayed in the library.
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.debugPutDownload(file('clip'));
      expect(controller.videos.map((e) => e.id), contains('clip'));

      await controller.deleteDownload(controller.videos.first);

      expect(controller.videos.map((e) => e.id), isNot(contains('clip')));
      expect(controller.trashedItems.map((e) => e.id), contains('clip'));
    });

    test('restoring puts it back in the list', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.debugPutDownload(file('clip'));
      await controller.deleteDownload(controller.videos.first);
      expect(controller.videos, isEmpty);

      await controller.restoreFromTrash(controller.trashedItems.first);

      expect(controller.videos.map((e) => e.id), contains('clip'));
      expect(controller.trashedItems, isEmpty);
    });

    test('deleting for good leaves no row at all', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.debugPutDownload(file('clip'));
      await controller.deleteDownload(controller.videos.first);
      await controller.deleteForever(controller.trashedItems.first);

      expect(controller.videos, isEmpty);
      expect(controller.trashedItems, isEmpty);
      expect(controller.downloads.map((e) => e.id), isNot(contains('clip')));
    });

    test('each page sees only its own deleted files', () async {
      // One trash with a filter over it, not a bin per media type. A video
      // deleted from the Videos tab and then looked for under Recently deleted
      // in Settings has to be the same row.
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.debugPutDownload(file('a-video'));
      await controller.debugPutDownload(
        file('a-song').copyWith(type: DownloadType.audio),
      );
      await controller.debugPutDownload(
        file('a-photo').copyWith(type: DownloadType.image),
      );

      for (final item in [...controller.videos, ...controller.audios, ...controller.images]) {
        await controller.deleteDownload(item);
      }

      expect(controller.trashedOf(DownloadType.video).map((e) => e.id), ['a-video']);
      expect(controller.trashedOf(DownloadType.audio).map((e) => e.id), ['a-song']);
      expect(controller.trashedOf(DownloadType.image).map((e) => e.id), ['a-photo']);
      // And the unfiltered view is still the whole thing.
      expect(controller.trashedItems, hasLength(3));
      expect(controller.trashCount(null), 3);
      expect(controller.trashCount(DownloadType.video), 1);
    });

    test('emptying a filtered view leaves the other kinds alone', () async {
      // Someone looking at deleted videos who taps empty is asking about
      // those, not about everything they have ever deleted.
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.debugPutDownload(file('a-video'));
      await controller.debugPutDownload(
        file('a-song').copyWith(type: DownloadType.audio),
      );
      await controller.deleteDownload(controller.videos.first);
      await controller.deleteDownload(controller.audios.first);

      await controller.emptyTrash(only: DownloadType.video);

      expect(controller.trashedOf(DownloadType.video), isEmpty);
      expect(controller.trashedOf(DownloadType.audio).map((e) => e.id), ['a-song']);
    });

    test('the days left count down and reach the last day', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      final justDeleted = file('a').copyWith(deletedAt: DateTime.now());
      expect(controller.daysLeftInTrash(justDeleted), 7);

      final nearlyGone = file('b').copyWith(
        deletedAt: DateTime.now().subtract(const Duration(days: 6, hours: 23)),
      );
      expect(controller.daysLeftInTrash(nearlyGone), 1);

      final overdue = file('c').copyWith(
        deletedAt: DateTime.now().subtract(const Duration(days: 9)),
      );
      expect(controller.daysLeftInTrash(overdue), 0);
    });

    test('deleting one file does not disturb another', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.debugPutDownload(file('keep'));
      await controller.debugPutDownload(file('drop'));

      await controller.deleteDownload(
        controller.videos.firstWhere((e) => e.id == 'drop'),
      );

      expect(controller.videos.map((e) => e.id), ['keep']);
    });
  });

  group('a video is not a track', () {
    DownloadItem video(String id) => DownloadItem(
      id: id,
      url: 'https://example.com/$id',
      title: 'A video',
      platform: 'Example',
      type: DownloadType.video,
      filePath: '/tmp/$id.mp4',
      createdAt: DateTime.utc(2026),
      status: DownloadStatus.completed,
      progress: 100,
      favorite: false,
    );

    test('the standby copy is not what the user is listening to', () async {
      // A video's silent standby used to be written into playingItem, which
      // is what the mini player reads — so a paused video sat in the audio bar
      // labelled "Audio file".
      final controller = createController();
      addTearDown(controller.dispose);

      controller.backgroundVideoItem = video('clip');

      expect(controller.playingItem, isNull);
    });

    test('closing the player leaves no bar behind', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      controller.backgroundVideoItem = video('clip');
      controller.playerItem = video('clip');

      controller.closePlayer();

      // Cleared in the same turn as the notify, not some frames later when the
      // platform call finishes — every one of those frames drew the bar.
      expect(controller.backgroundVideoItem, isNull);
      expect(controller.playingItem, isNull);
      expect(controller.playerItem, isNull);
    });

    test('closing does not disturb a track that is actually playing', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      final song = video('song').copyWith(type: DownloadType.audio);
      controller.playingItem = song;
      controller.playerItem = song;

      controller.closePlayer();

      // The bar is meant to survive closing the full player — that is the
      // whole point of it.
      expect(controller.playingItem, isNotNull);
      expect(controller.playerItem, isNull);
    });
  });

  group('where a video is left off', () {
    const id = 'clip-1';

    test('leaving in the middle comes back to the middle', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      controller.saveVideoResumePosition(
        id,
        const Duration(minutes: 2),
        duration: const Duration(minutes: 10),
      );

      expect(controller.videoResumePosition(id), const Duration(minutes: 2));
    });

    test('watching it to the end comes back to the start', () async {
      // The reported bug: a finished video reopened at its final second.
      final controller = createController();
      addTearDown(controller.dispose);

      controller.saveVideoResumePosition(
        id,
        const Duration(minutes: 5),
        duration: const Duration(minutes: 10),
      );
      controller.saveVideoResumePosition(
        id,
        const Duration(minutes: 10),
        duration: const Duration(minutes: 10),
      );

      expect(controller.videoResumePosition(id), Duration.zero);
    });

    test('the credits count as finished', () async {
      // The position is only written every few seconds, and people leave
      // during the credits rather than sitting through the last frame — so the
      // last point ever recorded is short of the end either way.
      final controller = createController();
      addTearDown(controller.dispose);

      controller.saveVideoResumePosition(
        id,
        const Duration(minutes: 9, seconds: 56),
        duration: const Duration(minutes: 10),
      );

      expect(controller.videoResumePosition(id), Duration.zero);
    });

    test('stopping just before the tail still resumes', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      controller.saveVideoResumePosition(
        id,
        const Duration(minutes: 9, seconds: 30),
        duration: const Duration(minutes: 10),
      );

      expect(
        controller.videoResumePosition(id),
        const Duration(minutes: 9, seconds: 30),
      );
    });

    test('finishing forgets a position already stored', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      controller.saveVideoResumePosition(
        id,
        const Duration(minutes: 4),
        duration: const Duration(minutes: 10),
      );
      expect(controller.videoResumePosition(id), const Duration(minutes: 4));

      controller.saveVideoResumePosition(
        id,
        const Duration(minutes: 10),
        duration: const Duration(minutes: 10),
      );
      expect(controller.videoResumePosition(id), Duration.zero);
    });

    test('an unknown length is saved as before', () async {
      // Callers that cannot supply one must not lose the feature.
      final controller = createController();
      addTearDown(controller.dispose);

      controller.saveVideoResumePosition(id, const Duration(minutes: 3));
      expect(controller.videoResumePosition(id), const Duration(minutes: 3));
    });

    test('one video finishing does not forget another', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      controller.saveVideoResumePosition(
        'other',
        const Duration(minutes: 1),
        duration: const Duration(minutes: 10),
      );
      controller.saveVideoResumePosition(
        id,
        const Duration(minutes: 10),
        duration: const Duration(minutes: 10),
      );

      expect(controller.videoResumePosition('other'), const Duration(minutes: 1));
      expect(controller.videoResumePosition(id), Duration.zero);
    });
  });

  group('one player, handed between two features', () {
    test('closing a video hands it back at the level the user set', () async {
      // The reported bug. Watching a video mutes this player on purpose — the
      // video's own track is the sound — and closing it used to stop playback
      // without undoing that, so the next song played perfectly and silently.
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.setPlaybackVolume(0.4);
      await controller.playback.acquire(PlaybackIntent.videoStandby);
      expect(controller.audioPlayer.volume, 0.0);

      await controller.playback.release();

      // Their level, not a hardcoded full volume. The video borrowed the
      // player; it does not get to overrule what its owner set.
      expect(controller.audioPlayer.volume, closeTo(0.4, 0.001));
    });

    test('every shared property comes back, not just the volume', () async {
      // Volume was the one that got noticed. Loop and speed sit on the same
      // object and can each do exactly the same thing.
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.audioPlayer.setSpeed(2.0);
      await controller.audioPlayer.setLoopMode(LoopMode.one);

      await controller.playback.acquire(PlaybackIntent.videoStandby);
      await controller.playback.release();

      expect(controller.audioPlayer.speed, 1.0);
      expect(controller.audioPlayer.loopMode, LoopMode.off);
      expect(controller.audioPlayer.volume, 1.0);
    });

    test('taking it for music makes it audible whatever came before', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.playback.acquire(PlaybackIntent.videoStandby);
      expect(controller.audioPlayer.volume, 0.0);

      await controller.playback.acquire(PlaybackIntent.music);
      expect(controller.audioPlayer.volume, 1.0);
      expect(controller.playback.isMusic, isTrue);
    });

    test('the video keeps it silent however the slider moves', () async {
      // Otherwise moving the slider during a video plays the same audio twice,
      // half a second apart.
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.playback.acquire(PlaybackIntent.videoStandby);
      await controller.setPlaybackVolume(0.8);

      expect(controller.audioPlayer.volume, 0.0);
      expect(controller.playbackVolume, 0.8);
    });

    test('locking the screen unmutes to the level the user set', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.setPlaybackVolume(0.6);
      await controller.playback.acquire(PlaybackIntent.videoStandby);
      await controller.playback.unmute();

      expect(controller.audioPlayer.volume, closeTo(0.6, 0.001));
    });

    test('nobody holding it is a released player', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      expect(controller.playback.intent, isNull);
      await controller.playback.acquire(PlaybackIntent.music);
      expect(controller.playback.intent, PlaybackIntent.music);
      await controller.playback.release();
      expect(controller.playback.intent, isNull);
    });

    test('the chosen level survives a restart', () async {
      final store = DownloadStore(box);
      await store.writePlaybackVolume(0.35);

      final controller = createController();
      addTearDown(controller.dispose);

      expect(controller.playbackVolume, closeTo(0.35, 0.001));
    });
  });

  group('the video hands its speed over, not its side effects', () {
    test('changing video speed leaves the shared player alone', () async {
      // The audio player is silent while a video is on screen, so setting its
      // rate then changes nothing anyone can hear — and leaves a value behind
      // for whatever holds it next.
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.playback.acquire(PlaybackIntent.videoStandby);
      controller.videoPlaybackSpeed = 2.0;

      expect(controller.audioPlayer.speed, 1.0);
    });

    test('the speed arrives when the sound does', () async {
      // Otherwise the sound snaps back to normal speed the moment the screen
      // goes off.
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.playback.acquire(PlaybackIntent.videoStandby);
      controller.videoPlaybackSpeed = 1.5;
      await controller.playback.setSpeed(controller.videoPlaybackSpeed);

      expect(controller.audioPlayer.speed, 1.5);
    });

    test('a released player takes no orders', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.playback.release();
      await controller.playback.setSpeed(2.0);

      expect(controller.audioPlayer.speed, 1.0);
    });
  });

  group('the app does not interrupt itself', () {
    test('an unclassified focus change never stops the video', () async {
      // The reported bug. Starting a video preloads its audio and plays it for
      // an instant to bring the background service up while that is still
      // allowed; Android reports the resulting focus change back as an
      // interruption of type "unknown", and acting on it paused the video a
      // second after it started.
      final controller = createController();
      addTearDown(controller.dispose);

      var videoPauses = 0;
      controller.addPausePlaybackHandler(() => videoPauses++);

      controller.debugHandleInterruption(
        begin: true,
        type: AudioInterruptionType.unknown,
      );

      expect(videoPauses, 0);
    });

    test('a real interruption still stops the video', () async {
      // A call, an alarm, another app taking over.
      final controller = createController();
      addTearDown(controller.dispose);

      var videoPauses = 0;
      controller.addPausePlaybackHandler(() => videoPauses++);

      controller.debugHandleInterruption(
        begin: true,
        type: AudioInterruptionType.pause,
      );

      expect(videoPauses, 1);
    });

    test('focus churn the app caused is ignored entirely', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      var videoPauses = 0;
      controller.addPausePlaybackHandler(() => videoPauses++);

      await controller.debugWithoutSelfInterruption(() async {
        // Exactly what the preload does: play for an instant, then stop.
        controller.debugHandleInterruption(
          begin: true,
          type: AudioInterruptionType.pause,
        );
      });

      expect(videoPauses, 0, reason: 'the app must not interrupt itself');
    });

    test('the guard closes again afterwards', () async {
      final controller = createController();
      addTearDown(controller.dispose);

      await controller.debugWithoutSelfInterruption(() async {});
      expect(controller.debugOwnAudioActivity, isTrue);

      // The focus callback lands after the call that caused it, so the window
      // stays open a beat — but it does close.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(controller.debugOwnAudioActivity, isFalse);

      var videoPauses = 0;
      controller.addPausePlaybackHandler(() => videoPauses++);
      controller.debugHandleInterruption(
        begin: true,
        type: AudioInterruptionType.pause,
      );
      expect(videoPauses, 1);
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
