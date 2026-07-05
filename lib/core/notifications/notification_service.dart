import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService() {
    _initialized = _tryInitialize();
  }

  late final Future<void> _initialized;
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void> _tryInitialize() async {
    if (kIsWeb) return;
    try {
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const settings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );
      await _plugin.initialize(settings);
    } catch (_) {
      // Notifications are best-effort; fail silently in test/CLI envs.
    }
  }

  Future<void> initialize() => _initialized;

  Future<void> showDownloadComplete({
    required int id,
    required String title,
    required String type,
  }) async {
    try {
      const androidDetails = AndroidNotificationDetails(
        'duck_downloads_quack',
        'Duck Downloads',
        channelDescription: 'Duck downloader completion notifications',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('quack_duck_sound'),
      );
      const details = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(
          presentSound: true,
          sound: 'quack_duck_sound.mp3',
        ),
      );
      await _plugin.show(
        id,
        'Download Complete',
        '$type "$title" has been downloaded.',
        details,
      );
    } catch (e, s) {
      debugPrint('NOTIFICATION ERROR (Complete): $e\n$s');
    }
  }

  Future<void> showDownloadFailed({
    required int id,
    required String title,
    required String error,
  }) async {
    try {
      const androidDetails = AndroidNotificationDetails(
        'duck_downloads_quack',
        'Duck Downloads',
        channelDescription: 'Duck downloader failure notifications',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('quack_duck_sound'),
      );
      const details = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(
          presentSound: true,
          sound: 'quack_duck_sound.mp3',
        ),
      );
      await _plugin.show(
        id,
        'Download Failed',
        '"$title" — $error',
        details,
      );
    } catch (e, s) {
      debugPrint('NOTIFICATION ERROR (Failed): $e\n$s');
    }
  }
}
