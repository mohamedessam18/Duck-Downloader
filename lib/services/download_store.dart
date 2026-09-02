import 'package:hive/hive.dart';

import '../models/download_models.dart';

class DownloadStore {
  DownloadStore(this._box);

  final Box _box;

  /// True while this store can still be used.
  ///
  /// Every write here is queued behind [_pendingWrites] and therefore runs
  /// after an `await` — sometimes after the box it writes to has been closed,
  /// because a download's status stream can outlive the screen that started
  /// it. Hive throws on a closed box, and it throws inside a detached async
  /// chain where nothing is listening, so the failure surfaces somewhere else
  /// entirely. A closed store does nothing instead.
  bool get isUsable => _box.isOpen;

  List<DownloadItem> readDownloads() {
    if (!isUsable) return const [];
    final raw = _box.get('downloads', defaultValue: const <dynamic>[]);
    if (raw is! List) return const [];
    final downloads = <DownloadItem>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        downloads.add(DownloadItem.fromJson(Map<String, dynamic>.from(item)));
      } catch (_) {}
    }
    return downloads;
  }

  /// The tail of the chain of in-flight writes to the downloads list.
  ///
  /// Every mutation here is read-modify-write of the *whole* list with an
  /// `await` in the middle, so two overlapping callers each read the same
  /// starting state and the second one's write erases the first one's change.
  /// Nothing overlapped while downloads ran one at a time; running three at
  /// once made items vanish from the library moments after being added.
  ///
  /// Chaining is enough — these are short, and the box is the only writer.
  Future<void> _pendingWrites = Future<void>.value();

  Future<T> _serialised<T>(Future<T> Function() mutate) {
    final result = _pendingWrites.then((_) => mutate());
    // The chain must survive a failed write, or one error would wedge every
    // later save behind it.
    _pendingWrites = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> writeDownloads(List<DownloadItem> downloads) {
    return _serialised(() => _writeDownloadsNow(downloads));
  }

  /// Rewrites the list from what is on disk right now.
  ///
  /// [transform] is handed the stored rows *inside* the write lock, so a
  /// caller cannot base its new list on a snapshot that another save has
  /// already moved past. Passing a list held in memory instead is how rows
  /// added a moment earlier get erased — which, with three downloads running
  /// at once, is most of them.
  Future<List<DownloadItem>> rewrite(
    List<DownloadItem> Function(List<DownloadItem> stored) transform,
  ) {
    return _serialised(() async {
      final next = transform(readDownloads());
      await _writeDownloadsNow(next);
      return next;
    });
  }

  Future<void> _writeDownloadsNow(List<DownloadItem> downloads) {
    if (!isUsable) return Future<void>.value();
    return _box.put('downloads', [
      for (final item in downloads) _storedItem(item).toJson(),
    ]);
  }

  DownloadItem _storedItem(DownloadItem item) {
    if (!item.isPrivate) return item;
    return DownloadItem(
      id: item.id,
      url: '',
      title: 'Private download',
      platform: '',
      type: item.type,
      filePath: item.filePath,
      createdAt: item.createdAt,
      status: item.status,
      progress: item.progress,
      favorite: item.favorite,
      savedToGallery: item.savedToGallery,
      savedToMusic: item.savedToMusic,
      isPrivate: true,
    );
  }

  bool readAutoSaveVideos() {
    final value = _box.get('autoSaveVideos');
    return value is bool ? value : true;
  }

  Future<void> writeAutoSaveVideos(bool enabled) {
    return _box.put('autoSaveVideos', enabled);
  }

  bool readEnableClipboardDetection() {
    final value = _box.get('enableClipboardDetection');
    return value is bool ? value : true;
  }

  Future<void> writeEnableClipboardDetection(bool enabled) {
    return _box.put('enableClipboardDetection', enabled);
  }

  /// False until the user has been through (or skipped) the intro.
  ///
  /// Defaults to *true* when the box already holds downloads: an existing user
  /// updating the app has clearly used it before, and dropping them into a
  /// first-run intro would be baffling.
  bool readOnboardingCompleted() {
    final value = _box.get('onboardingCompleted');
    if (value is bool) return value;
    final existing = _box.get('downloads');
    return existing is List && existing.isNotEmpty;
  }

  Future<void> writeOnboardingCompleted(bool completed) {
    return _box.put('onboardingCompleted', completed);
  }

  /// One-shot: set when the intro finishes, cleared the moment the offer is
  /// shown. Kept in storage rather than in memory so the offer survives the
  /// splash screen between the intro and the main screen.
  bool readPendingPremiumOffer() {
    return _box.get('pendingPremiumOffer') == true;
  }

  Future<void> writePendingPremiumOffer(bool pending) {
    return _box.put('pendingPremiumOffer', pending);
  }

  /// Whether the one-time bulk "allow Duck to modify your media" request has
  /// already been put to the user.
  ///
  /// Stored rather than kept in memory because the grant it obtains outlives
  /// the process: re-asking on every launch would be nagging for something the
  /// system already remembers.
  bool readMediaWriteAccessAsked() {
    final value = _box.get('mediaWriteAccessAsked');
    return value is bool ? value : false;
  }

  Future<void> writeMediaWriteAccessAsked(bool asked) {
    return _box.put('mediaWriteAccessAsked', asked);
  }

  bool readCrashReportingEnabled() {
    final value = _box.get('crashReportingEnabled');
    return value is bool ? value : true;
  }

  Future<void> writeCrashReportingEnabled(bool enabled) {
    return _box.put('crashReportingEnabled', enabled);
  }

  Future<DownloadItem> upsert(DownloadItem item) {
    return _serialised(() => _upsertNow(item));
  }

  Future<DownloadItem> _upsertNow(DownloadItem item) async {
    if (!isUsable) return item;
    final items = readDownloads();
    final index = items.indexWhere((existing) => existing.id == item.id);
    if (index >= 0) {
      items[index] = items[index].copyWith(
        url: item.url,
        title: item.title,
        thumbnail: item.thumbnail,
        platform: item.platform,
        quality: item.quality,
        type: item.type,
        filePath: item.filePath,
        createdAt: item.createdAt,
        status: item.status,
        progress: item.progress,
        favorite: item.favorite,
        savedToGallery: item.savedToGallery,
        savedToMusic: item.savedToMusic,
        isPrivate: item.isPrivate,
        externalSaveError: item.externalSaveError,
        artist: item.artist,
        album: item.album,
      );
    } else {
      items.insert(0, item);
    }
    await _writeDownloadsNow(items);
    return item;
  }

  Future<void> delete(String id) {
    return _serialised(() async {
      if (!isUsable) return;
      final items = readDownloads()..removeWhere((item) => item.id == id);
      await _writeDownloadsNow(items);
    });
  }

  /// The volume the user last chose, as a fraction of full.
  ///
  /// Persisted because the player is shared: watching a video mutes it, and
  /// handing it back means handing back the level its owner set — which the
  /// app has to still know after a restart, or the slider is a control that
  /// forgets itself.
  double readPlaybackVolume() {
    final value = _box.get('playbackVolume');
    if (value is num) return value.toDouble().clamp(0.0, 1.0);
    return 1.0;
  }

  Future<void> writePlaybackVolume(double volume) {
    if (!isUsable) return Future<void>.value();
    return _box.put('playbackVolume', volume.clamp(0.0, 1.0));
  }

  List<Playlist> readPlaylists() {
    final raw = _box.get('playlists', defaultValue: const <dynamic>[]);
    if (raw is! List) return const [];
    final playlists = <Playlist>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        playlists.add(Playlist.fromJson(Map<String, dynamic>.from(item)));
      } catch (_) {}
    }
    return playlists;
  }

  Future<void> writePlaylists(List<Playlist> playlists) {
    return _box.put('playlists', [for (final item in playlists) item.toJson()]);
  }

  String? readVaultPin() {
    return _box.get('vaultPin') as String?;
  }

  Future<void> writeVaultPin(String? pin) {
    if (pin == null) {
      return _box.delete('vaultPin');
    }
    return _box.put('vaultPin', pin);
  }

  String? readDecoyVaultPin() {
    return _box.get('decoyVaultPin') as String?;
  }

  Future<void> writeDecoyVaultPin(String? pin) {
    if (pin == null) {
      return _box.delete('decoyVaultPin');
    }
    return _box.put('decoyVaultPin', pin);
  }

  bool readBiometricEnabled() {
    final value = _box.get('biometricEnabled');
    return value is bool ? value : false;
  }

  Future<void> writeBiometricEnabled(bool enabled) {
    return _box.put('biometricEnabled', enabled);
  }

  Map<String, int> readVideoResumePositions() {
    final raw = _box.get('videoResumePositions', defaultValue: <dynamic>{});
    if (raw is! Map) return {};
    return raw.map((key, value) => MapEntry('$key', (value as num).toInt()));
  }

  Future<void> writeVideoResumePosition(String id, int milliseconds) {
    if (!isUsable) return Future<void>.value();
    final positions = readVideoResumePositions();
    positions[id] = milliseconds;
    return _box.put('videoResumePositions', positions);
  }

  /// Drops the entry rather than storing a zero, so the map does not grow a
  /// row for every video anyone ever finished.
  Future<void> clearVideoResumePosition(String id) {
    if (!isUsable) return Future<void>.value();
    final positions = readVideoResumePositions();
    if (positions.remove(id) == null) return Future<void>.value();
    return _box.put('videoResumePositions', positions);
  }

  bool readShuffleEnabled() {
    final value = _box.get('shuffleEnabled');
    return value is bool ? value : false;
  }

  Future<void> writeShuffleEnabled(bool enabled) {
    return _box.put('shuffleEnabled', enabled);
  }

  /// Stored by name rather than index: `LoopMode`'s ordering belongs to
  /// just_audio, and a reorder there would silently turn everyone's
  /// repeat-one into repeat-all.
  String? readPlaybackLoopMode() {
    final value = _box.get('playbackLoopMode');
    return value is String ? value : null;
  }

  Future<void> writePlaybackLoopMode(String name) {
    return _box.put('playbackLoopMode', name);
  }

  String? readYoutubeCookies() {
    return _box.get('youtubeCookies') as String?;
  }

  Future<void> writeYoutubeCookies(String? cookies) {
    if (cookies == null) {
      return _box.delete('youtubeCookies');
    }
    return _box.put('youtubeCookies', cookies);
  }

  String? readLastDownloadType() {
    return _box.get('lastDownloadType') as String?;
  }

  Future<void> writeLastDownloadType(String type) {
    return _box.put('lastDownloadType', type);
  }

  String? readLastVideoQuality() {
    return _box.get('lastVideoQuality') as String?;
  }

  Future<void> writeLastVideoQuality(String quality) {
    return _box.put('lastVideoQuality', quality);
  }

  String? readLastAudioQuality() {
    return _box.get('lastAudioQuality') as String?;
  }

  Future<void> writeLastAudioQuality(String quality) {
    return _box.put('lastAudioQuality', quality);
  }

  String? readLastImageQuality() {
    return _box.get('lastImageQuality') as String?;
  }

  Future<void> writeLastImageQuality(String quality) {
    return _box.put('lastImageQuality', quality);
  }
}
