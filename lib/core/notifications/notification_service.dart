import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

typedef NotificationTapHandler = void Function(String? payload);

class NotificationService {
  NotificationService();

  late final Future<void> _initialized = _tryInitialize();
  NotificationTapHandler? _onTap;

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // Channel IDs — bump suffix to force re-creation with correct sound
  static const _successChannelId = 'duck_downloads_success_v4';
  static const _failChannelId = 'duck_downloads_fail_v4';
  static const _clipboardChannelId = 'duck_clipboard_v4';

  Future<void> _tryInitialize() async {
    if (kIsWeb) return;
    try {
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
        defaultPresentAlert: true,
        defaultPresentBadge: true,
        defaultPresentSound: true,
      );
      const settings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (response) {
          _onTap?.call(response.payload);
        },
      );

      // ── Android 8+ requires explicit channel creation with sound ──────────
      // The sound is tied to the channel, not the individual notification.
      // We must call createNotificationChannel() so the OS registers the
      // custom sound before the first notification is shown.
      if (!kIsWeb && Platform.isAndroid) {
        await _createAndroidChannels();
      }
    } catch (_) {
      // Notifications are best-effort; fail silently in test/CLI envs.
    }
  }

  Future<void> _createAndroidChannels() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;

    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        _successChannelId,
        'Duck Downloads',
        description: 'Download completed notifications',
        importance: Importance.max,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('quack_success'),
        enableVibration: true,
      ),
    );

    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        _failChannelId,
        'Duck Download Errors',
        description: 'Download failure notifications',
        importance: Importance.max,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('quack_fail'),
        enableVibration: true,
      ),
    );

    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        _clipboardChannelId,
        'Duck Clipboard',
        description: 'Clipboard link detected notifications',
        importance: Importance.high,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('quack_clipboard'),
        enableVibration: false,
      ),
    );
  }

  Future<void> initialize({NotificationTapHandler? onTap}) async {
    _onTap = onTap;
    await _initialized;
  }

  Future<void> showDownloadComplete({
    required int id,
    required String title,
    required String type,
    String? downloadId,
  }) async {
    await _initialized;
    try {
      const androidDetails = AndroidNotificationDetails(
        _successChannelId,
        'Duck Downloads',
        channelDescription: 'Download completed notifications',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        sound: RawResourceAndroidNotificationSound('quack_success'),
      );
      const details = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          sound: 'quack_success.mp3',
        ),
      );
      await _plugin.show(
        id,
        'Download Complete',
        '$type "$title" has been downloaded.',
        details,
        payload: downloadId,
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
    await _initialized;
    try {
      const androidDetails = AndroidNotificationDetails(
        _failChannelId,
        'Duck Download Errors',
        channelDescription: 'Download failure notifications',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        sound: RawResourceAndroidNotificationSound('quack_fail'),
      );
      const details = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          sound: 'quack_fail.mp3',
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

  Future<void> showClipboardDetected({
    required int id,
    required String url,
  }) async {
    await _initialized;
    try {
      const androidDetails = AndroidNotificationDetails(
        _clipboardChannelId,
        'Duck Clipboard',
        channelDescription: 'Clipboard link detected notifications',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: false,
        sound: RawResourceAndroidNotificationSound('quack_clipboard'),
      );
      const details = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: true,
          sound: 'quack_clipboard.mp3',
        ),
      );
      await _plugin.show(
        id,
        'Link Detected',
        'Tap Duck Downloader to download this link.',
        details,
      );
    } catch (e, s) {
      debugPrint('NOTIFICATION ERROR (Clipboard): $e\n$s');
    }
  }
}
