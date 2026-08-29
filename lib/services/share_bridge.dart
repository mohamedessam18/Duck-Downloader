import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/download_models.dart';

/// The handover between the native share flow and the app's library.
///
/// A link shared from Facebook is downloaded by `DownloadService` while Duck
/// is closed. That service cannot write to Hive — Hive is not safe to open
/// from two places, and the app may well be running — so it appends finished
/// downloads to a list in SharedPreferences. This drains that list.
class ShareBridge {
  ShareBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('duck_downloader/media');

  final MethodChannel _channel;

  /// Tells the native side which backend to talk to.
  ///
  /// The share sheet extracts qualities before any Flutter engine exists, so
  /// it holds its own copy of the base URL. Pushing the resolved one here on
  /// every launch is what keeps a `--dart-define=DUCK_API_BASE_URL` override
  /// from applying to half the app.
  Future<void> syncConfig({required String apiBaseUrl}) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('syncShareConfig', {'apiBaseUrl': apiBaseUrl});
    } on PlatformException catch (error) {
      debugPrint('Could not sync share config: ${error.message}');
    } on MissingPluginException {
      // Older native build, or a platform without the share service.
    }
  }

  /// Holds the process open while downloads are running.
  ///
  /// Safe to call repeatedly — the service treats each call as the current
  /// state of the notification rather than a new request.
  Future<void> holdKeepAlive({
    required String title,
    required int percent,
    required int running,
    required int total,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('keepDownloadsAlive', {
        'title': title,
        'percent': percent,
        'running': running,
        'total': total,
      });
    } on PlatformException catch (error) {
      debugPrint('Could not hold the download service: ${error.message}');
    } on MissingPluginException {
      // Older native build: downloads still work, they just do not survive
      // being backgrounded.
    }
  }

  Future<void> releaseKeepAlive() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('releaseDownloadsAlive');
    } on PlatformException catch (error) {
      debugPrint('Could not release the download service: ${error.message}');
    } on MissingPluginException {
      // Nothing was holding it.
    }
  }

  /// Takes everything the service finished and clears it in the same call.
  ///
  /// Read-and-clear is atomic on the native side: a download handed over here
  /// is gone from the inbox, so a resume that races a cold start cannot add
  /// the same file to the library twice.
  Future<List<DownloadItem>> drain() async {
    if (!Platform.isAndroid) return const [];
    String payload;
    try {
      payload = await _channel.invokeMethod<String>('drainShareInbox') ?? '[]';
    } on PlatformException catch (error) {
      debugPrint('Could not read the share inbox: ${error.message}');
      return const [];
    } on MissingPluginException {
      return const [];
    }

    late final List<dynamic> raw;
    try {
      raw = jsonDecode(payload) as List<dynamic>;
    } catch (error) {
      debugPrint('Share inbox was unreadable: $error');
      return const [];
    }

    final items = <DownloadItem>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final item = _toItem(Map<String, dynamic>.from(entry));
      if (item != null) items.add(item);
    }
    return items;
  }

  DownloadItem? _toItem(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    final url = json['url']?.toString();
    if (id == null || id.isEmpty || url == null || url.isEmpty) return null;

    final failed = json['status']?.toString() == 'failed';
    final filePath = json['filePath']?.toString();
    // A "completed" record with no file on disk is not something to show as a
    // finished download; the file was cleaned up, or the save never landed.
    final missing =
        !failed && (filePath == null || !File(filePath).existsSync());

    return DownloadItem(
      id: id,
      url: url,
      title: json['title']?.toString() ?? 'Download',
      thumbnail: json['thumbnail']?.toString(),
      platform: json['platform']?.toString() ?? 'Public source',
      quality: json['quality']?.toString(),
      type: _typeOf(json['type']?.toString()),
      filePath: failed || missing ? null : filePath,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      status: failed || missing
          ? DownloadStatus.failed
          : DownloadStatus.completed,
      progress: failed || missing ? 0 : 100,
      favorite: false,
      // The service already published the file to the media library.
      savedToGallery: !failed && !missing && _typeOf(json['type']?.toString()) == DownloadType.video,
      savedToMusic: !failed && !missing && _typeOf(json['type']?.toString()) == DownloadType.audio,
    );
  }

  DownloadType _typeOf(String? name) {
    switch (name) {
      case 'audio':
        return DownloadType.audio;
      case 'image':
        return DownloadType.image;
      default:
        return DownloadType.video;
    }
  }
}
