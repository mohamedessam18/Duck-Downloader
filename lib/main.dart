import 'package:flutter/widgets.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app.dart';
import 'services/ad_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AdService.instance.initialize();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.duck.downloader.audio',   
    androidNotificationChannelName: 'Duck Audio Playback',
    androidNotificationOngoing: true,
  );
  await Hive.initFlutter();
  await Hive.openBox('duck-downloads');
  runApp(const DuckDownloaderApp());
}