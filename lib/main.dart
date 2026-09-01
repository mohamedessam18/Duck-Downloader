import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app.dart';
import 'services/ad_service.dart';
import 'services/crash_reporting_service.dart';
import 'services/download_store.dart';
import 'services/vault_encryption_service.dart';
import 'services/youtube_explode_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Draw behind thestatus bar and the gesture bar, on every Android version.
  //
  // Android 15 forces this on any app targeting SDK 35 whether it asks or not,
  // so without the explicit opt-in the app would be edge-to-edge on 15+ and
  // letterboxed everywhere else — two layouts to reason about instead of one.
  // Play calls that out as "edge-to-edge may not display for all users".
  //
  // Nothing else has to change to make this safe: the screens already read
  // MediaQuery.paddingOf(context).bottom and wrap their content in SafeArea,
  // which is what keeps the last row of a list clear of the gesture bar.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // Completely disable all logging in release builds to eliminate security risks
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  // Storage first: crash reporting needs the user's opt-out before it starts
  // collecting anything, and that flag lives in the downloads box.
  await Hive.initFlutter();
  await _openDownloadsBox();

  // Then crash reporting, ahead of the remaining init. Everything below can
  // fail — the ad SDK, the audio service, the vault — and those early crashes
  // are the ones worth catching, because the user just sees a launch that dies.
  await CrashReportingService.instance.initialize(
    collectionEnabled:
        DownloadStore(Hive.box('duck-downloads')).readCrashReportingEnabled(),
  );

  // Storage recovery happened before the reporter existed. File it now — a
  // wiped box is data loss, and it is invisible from the dashboard otherwise.
  final storageRecovery = _pendingStorageRecovery;
  if (storageRecovery != null) {
    reportError(storageRecovery.$1, storageRecovery.$2,
        reason: 'downloads-box-unreadable');
    _pendingStorageRecovery = null;
  }

  CrashReportingService.instance.setStage('ads');
  try {
    await AdService.instance.initialize();
  } catch (error, stackTrace) {
    reportError(error, stackTrace, reason: 'ad-sdk-init');
  }
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.duck.downloader.audio',
      androidNotificationChannelName: 'Duck Audio Playback',
      androidNotificationOngoing: true,
    );
  } catch (error, stackTrace) {
    reportError(error, stackTrace, reason: 'audio-background-init');
  }

  CrashReportingService.instance.setStage('vault');
  await VaultEncryptionService.initialize();

  // Playing vault media writes a decrypted copy to the temp directory. It is
  // removed when the player closes and when the vault locks, but a crash or a
  // force-stop leaves plaintext on disk until something clears it — so sweep
  // on every cold start before any UI can open. Fire-and-forget: a slow sweep
  // must not delay launch.
  unawaited(VaultEncryptionService.cleanVaultTempFiles());

  // Same idea for download intermediates: a job killed mid-merge used to leave
  // a `<title>_temp_a.m4a` behind, which then showed up in the user's audio
  // folders as a duplicate of the video they downloaded.
  unawaited(YouTubeExplodeService.cleanOrphanedWorkFiles());

  CrashReportingService.instance.setStage('ready');
  runApp(const DuckDownloaderApp());
}

/// A storage failure caught before crash reporting was running.
(Object, StackTrace)? _pendingStorageRecovery;

Future<void> _openDownloadsBox() async {
  try {
    await Hive.openBox('duck-downloads');
  } catch (error, stackTrace) {
    // Reported once Crashlytics is up: this runs before it starts, and it is
    // the difference between "lost their whole library" and a clean install.
    debugPrint('Recovering unreadable local data: $error\n$stackTrace');
    _pendingStorageRecovery = (error, stackTrace);
    await Hive.deleteBoxFromDisk('duck-downloads');
    await Hive.openBox('duck-downloads');
  }
}
