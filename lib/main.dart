import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app.dart';
import 'services/ad_service.dart';
import 'services/vault_encryption_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Completely disable all logging in release builds to eliminate security risks
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  try {
    await AdService.instance.initialize();
  } catch (error, stackTrace) {
    debugPrint('Ad SDK initialization failed: $error\n$stackTrace');
  }
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.duck.downloader.audio',
      androidNotificationChannelName: 'Duck Audio Playback',
      androidNotificationOngoing: true,
    );
  } catch (error, stackTrace) {
    debugPrint('Audio background initialization failed: $error\n$stackTrace');
  }
  await Hive.initFlutter();
  await VaultEncryptionService.initialize();
  await _openDownloadsBox();
  runApp(const DuckDownloaderApp());
}

Future<void> _openDownloadsBox() async {
  try {
    await Hive.openBox('duck-downloads');
  } catch (error, stackTrace) {
    debugPrint('Recovering unreadable local data: $error\n$stackTrace');
    await Hive.deleteBoxFromDisk('duck-downloads');
    await Hive.openBox('duck-downloads');
  }
}
