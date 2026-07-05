import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';

import '../core/notifications/notification_service.dart';
import '../core/permissions/permission_service.dart';
import '../models/browser_image_candidate.dart';
import '../models/download_models.dart';
import '../services/api_client.dart';
import '../services/clipboard_service.dart';
import '../services/download_store.dart';
import '../services/file_service.dart';
import '../services/premium_entitlement.dart';
import '../services/premium_manager.dart';
import '../services/media_save_service.dart';

class DuckDownloadsController extends ChangeNotifier
    with WidgetsBindingObserver {
  DuckDownloadsController({
    required DuckApiClient api,
    required DuckClipboardService clipboard,
    required DuckFileService files,
    required MediaSaveService mediaSaver,
    required DownloadStore store,
    required PremiumManager premiumManager,
    NotificationService? notificationService,
    PermissionService? permissionService,
    bool initializePremium = true,
  }) : _api = api,
       _clipboard = clipboard,
       _files = files,
       _mediaSaver = mediaSaver,
       _store = store,
       premium = premiumManager,
       _notifications = notificationService ?? NotificationService(),
       _permissions = permissionService ?? PermissionService() {
    _downloads = _store.readDownloads();
    autoSaveVideos = _store.readAutoSaveVideos();
    enableClipboardDetection = _store.readEnableClipboardDetection();
    _playlists = _store.readPlaylists();
    _vaultPin = _store.readVaultPin();
    premium.addListener(_premiumChanged);
    if (initializePremium) {
      unawaited(premium.initialize());
    }
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkClipboardOnResume();
    });
    unawaited(_notifications.initialize());
    unawaited(_permissions.requestAllRequiredPermissions());
    unawaited(loadCookiesStatus());
    _playerStateSubscription = audioPlayer.playerStateStream.listen((_) {
      notifyListeners();
    });
    _playerPositionSubscription = audioPlayer.positionStream.listen((_) {
      notifyListeners();
    });
  }

  final AudioPlayer audioPlayer = AudioPlayer();
  final AudioPlayer _quackPlayer = AudioPlayer();
  late final StreamSubscription<PlayerState> _playerStateSubscription;
  late final StreamSubscription<Duration> _playerPositionSubscription;
  DownloadItem? playingItem;

  bool get isAudioPlaying => audioPlayer.playing;
  Duration get audioPosition => audioPlayer.position;
  Duration get audioDuration => audioPlayer.duration ?? Duration.zero;
  PlayerState get audioPlayerState => audioPlayer.playerState;

  final DuckApiClient _api;
  final DuckClipboardService _clipboard;
  final DuckFileService _files;
  final MediaSaveService _mediaSaver;
  final DownloadStore _store;
  final PremiumManager premium;
  final NotificationService _notifications;
  final PermissionService _permissions;

  List<DownloadItem> _downloads = [];
  List<Playlist> _playlists = [];
  String? _vaultPin;
  bool get isVaultSetup => _vaultPin != null;
  bool isVaultLocked = true;

  DuckFlow flow = DuckFlow.idle;
  DuckTab tab = DuckTab.home;
  String status = 'Tap the duck';
  MediaMetadata? metadata;
  List<PlaylistItem>? batchItems;
  String? batchTitle;
  String? batchPlatform;
  DownloadType selectedType = DownloadType.video;
  BackendCookiesInfo? backendCookies;
  LockedBrowserRequest? lockedBrowserRequest;
  String quality = 'Best';
  bool busy = false;
  bool autoSaveVideos = true;
  bool enableClipboardDetection = true;
  String? detectedClipboardUrl;
  String? _lastDetectedUrl;
  bool externalSaveBusy = false;
  String? activeId;
  DownloadItem? playerItem;
  final Set<String> controlPendingIds = {};

  bool removeMusic = false;

  void toggleRemoveMusic(bool value) {
    removeMusic = value;
    notifyListeners();
  }

  void clearLockedBrowserRequest() {
    lockedBrowserRequest = null;
    notifyListeners();
  }

  void _requestLockedBrowser(String url, String platform) {
    lockedBrowserRequest = LockedBrowserRequest(url: url, platform: platform);
    flow = DuckFlow.ready;
    status = 'Open Duck Downloader browser to finish image download';
  }

  Future<void> startBrowserImageDownloads({
    required List<BrowserImageCandidate> candidates,
    required String platform,
  }) async {
    final items = <PlaylistItem>[];
    for (final candidate in candidates) {
      if (candidate.isPreview) continue;
      items.add(candidate.toPlaylistItem(items.length + 1));
    }
    if (items.isEmpty) {
      flow = DuckFlow.error;
      status = 'Could not find full-size images on this page.';
      notifyListeners();
      return;
    }

    if (items.length == 1) {
      final singleItem = items[0];
      batchItems = items;
      batchPlatform = platform;
      await startBatchDownload(
        urls: [singleItem.url],
        type: singleItem.isVideo ? DownloadType.video : DownloadType.image,
        quality: 'Best',
      );
      clearBatch();
      return;
    }

    batchTitle = '$platform Images';
    batchPlatform = platform;
    batchItems = items;
    selectedType = DownloadType.image;
    quality = 'Best';
    flow = DuckFlow.ready;
    status = 'Choose images to download';
    notifyListeners();
  }

  bool get isPremiumActive => premium.isPremium;
  bool get isMusicPremiumActive =>
      hasPremiumFeature(PremiumFeature.musicRemoval);
  bool get premiumBusy => premium.loadingProducts || premium.purchasePending;
  bool get premiumStoreAvailable => premium.storeAvailable;
  String get premiumStatus => premium.errorMessage ?? premium.statusMessage;
  String? get premiumError => premium.errorMessage;
  List<SubscriptionProduct> get subscriptionProducts => premium.products;
  SubscriptionProduct? subscriptionProduct(SubscriptionPlan plan) =>
      premium.productFor(plan);
  bool hasPremiumFeature(PremiumFeature feature) => premium.hasFeature(feature);

  Future<void> subscribeToPremium(SubscriptionPlan plan) =>
      premium.subscribe(plan);
  Future<void> restorePurchases() => premium.restorePurchases();

  void _premiumChanged() {
    notifyListeners();
  }

  List<DownloadItem> get downloads => List.unmodifiable(_downloads);
  List<Playlist> get playlists => List.unmodifiable(_playlists);
  List<DownloadItem> get videos => _completed(DownloadType.video);
  List<DownloadItem> get audios => _completed(DownloadType.audio);
  List<DownloadItem> get images => _completed(DownloadType.image);
  List<DownloadItem> get privateDownloads =>
      _downloads
          .where(
            (item) => item.isPrivate && item.status == DownloadStatus.completed,
          )
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  List<DownloadItem> get activeDownloads {
    final items =
        _downloads
            .where(
              (item) =>
                  item.status == DownloadStatus.queued ||
                  item.status == DownloadStatus.downloading ||
                  item.status == DownloadStatus.processing ||
                  item.status == DownloadStatus.paused,
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return items;
  }

  DownloadItem? get activeDownload {
    final active = activeDownloads;
    if (active.isEmpty) return null;
    return active.where((item) => item.id == activeId).firstOrNull ?? active[0];
  }

  List<DownloadItem> _completed(DownloadType type) {
    return _downloads
        .where(
          (item) =>
              item.type == type &&
              item.status == DownloadStatus.completed &&
              !item.isPrivate,
        )
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  final List<DuckTab> tabHistory = [];

  void setTab(DuckTab next) {
    if (tab != next) {
      if (tabHistory.isEmpty || tabHistory.last != tab) {
        tabHistory.add(tab);
      }
      tab = next;
      notifyListeners();
    }
  }

  bool popTabHistory() {
    if (tabHistory.isNotEmpty) {
      tab = tabHistory.removeLast();
      notifyListeners();
      return true;
    }
    if (tab != DuckTab.home) {
      tab = DuckTab.home;
      notifyListeners();
      return true;
    }
    return false;
  }

  bool checkVaultPin(String pin) {
    if (pin == _vaultPin) {
      isVaultLocked = false;
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<void> setVaultPin(String pin) async {
    _vaultPin = pin;
    await _store.writeVaultPin(pin);
    notifyListeners();
  }

  void lockVault() {
    isVaultLocked = true;
    notifyListeners();
  }

  Future<void> toggleFavorite(DownloadItem item) async {
    final next = item.copyWith(favorite: !item.favorite);
    await _saveItem(next);
  }

  Future<void> moveItemToVault(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) throw Exception('File not available locally.');
    final ext = item.isAudio ? 'mp3' : 'mp4';
    final filename = item.title.toLowerCase().endsWith('.$ext')
        ? item.title
        : '${item.title}.$ext';
    final vaultPath = await _files.moveFileToVault(
      currentPath: path,
      filename: filename,
    );
    final next = item.copyWith(isPrivate: true, filePath: vaultPath);
    await _saveItem(next);
    status = 'Moved to Secure Vault';
    notifyListeners();
  }

  Future<void> moveItemFromVault(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) throw Exception('File not available locally.');
    final ext = item.isAudio ? 'mp3' : 'mp4';
    final filename = item.title.toLowerCase().endsWith('.$ext')
        ? item.title
        : '${item.title}.$ext';
    final destPath = await _files.moveFileFromVault(
      currentPath: path,
      filename: filename,
      type: item.type,
    );
    final next = item.copyWith(isPrivate: false, filePath: destPath);
    await _saveItem(next);
    status = 'Restored from Secure Vault';
    notifyListeners();
  }

  Future<void> createPlaylist(String name) async {
    if (name.trim().isEmpty) return;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final p = Playlist(
      id: id,
      name: name.trim(),
      downloadIds: const [],
      createdAt: DateTime.now(),
    );
    _playlists.add(p);
    await _store.writePlaylists(_playlists);
    _playlists = _store.readPlaylists();
    status = 'Playlist "${p.name}" created';
    notifyListeners();
  }

  Future<void> deletePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    await _store.writePlaylists(_playlists);
    _playlists = _store.readPlaylists();
    status = 'Playlist deleted';
    notifyListeners();
  }

  Future<void> addDownloadToPlaylist(
    String playlistId,
    String downloadId,
  ) async {
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx >= 0) {
      final playlist = _playlists[idx];
      if (!playlist.downloadIds.contains(downloadId)) {
        final nextIds = List<String>.from(playlist.downloadIds)
          ..add(downloadId);
        _playlists[idx] = playlist.copyWith(downloadIds: nextIds);
        await _store.writePlaylists(_playlists);
        _playlists = _store.readPlaylists();
        status = 'Added to playlist';
        notifyListeners();
      }
    }
  }

  Future<void> removeDownloadFromPlaylist(
    String playlistId,
    String downloadId,
  ) async {
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx >= 0) {
      final playlist = _playlists[idx];
      if (playlist.downloadIds.contains(downloadId)) {
        final nextIds = List<String>.from(playlist.downloadIds)
          ..remove(downloadId);
        _playlists[idx] = playlist.copyWith(downloadIds: nextIds);
        await _store.writePlaylists(_playlists);
        _playlists = _store.readPlaylists();
        status = 'Removed from playlist';
        notifyListeners();
      }
    }
  }

  void openPlayer(DownloadItem item) {
    playerItem = item;
    notifyListeners();
  }

  void closePlayer() {
    playerItem = null;
    notifyListeners();
  }

  Future<void> _extractUrlOrBatch(String url) async {
    metadata = null;
    batchItems = null;
    batchTitle = null;
    batchPlatform = null;
    lockedBrowserRequest = null;

    final cleanUrl = url.trim();
    final isPlaylist =
        cleanUrl.contains('list=') || cleanUrl.contains('/playlist');
    final lines = cleanUrl
        .split(RegExp(r'\s+'))
        .where((s) => _isPublicMediaCandidate(s))
        .toList();

    if (lines.length > 1) {
      batchTitle = 'Batch Links (${lines.length})';
      batchPlatform = 'Multiple Links';
      batchItems = lines.map((u) => PlaylistItem(url: u, title: u)).toList();
      selectedType = DownloadType.video;
      quality = 'Best';
      flow = DuckFlow.ready;
      status = 'Choose videos to download';
    } else if (isPlaylist) {
      flow = DuckFlow.extracting;
      status = 'Extracting playlist...';
      notifyListeners();
      final playlist = await _api.extractPlaylist(cleanUrl);
      batchTitle = playlist.title;
      batchPlatform = playlist.platform;
      batchItems = playlist.items;
      selectedType = DownloadType.video;
      quality = 'Best';
      flow = DuckFlow.ready;
      status = 'Choose videos to download';
    } else {
      if (!_isPublicMediaCandidate(cleanUrl)) {
        throw Exception('Copy a public social media link first.');
      }
      if (cleanUrl.contains('instagram.com')) {
        try {
          final playlist = await _api.extractPlaylist(cleanUrl);
          if (playlist.items.isNotEmpty) {
            if (playlist.items.length > 1) {
              // Carousel ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â show all images as batch
              batchTitle = playlist.title;
              batchPlatform = playlist.platform;
              batchItems = playlist.items;
              selectedType = DownloadType.image;
              quality = 'Best';
              flow = DuckFlow.ready;
              status = 'Choose images to download';
            } else {
              // Single image post ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â download directly as image
              batchTitle = playlist.title;
              batchPlatform = playlist.platform;
              batchItems = playlist.items;
              selectedType = DownloadType.image;
              quality = 'Best';
              flow = DuckFlow.ready;
              status = 'Tap download to save image';
            }
            return;
          }
        } catch (error) {
          if (_shouldUseLockedBrowserFallback(cleanUrl, error)) {
            _requestLockedBrowser(cleanUrl, _browserPlatformFor(cleanUrl));
            return;
          }
        }
      }
      try {
        final media = await _api.extract(cleanUrl);
        metadata = media;
        if (_isImageMetadata(media) || _looksLikeImageUrl(cleanUrl)) {
          selectedType = DownloadType.image;
          quality = _firstQuality(media, DownloadType.image);
          flow = DuckFlow.ready;
          status = 'Tap download to save image';
        } else {
          selectedType = DownloadType.video;
          quality = _firstQuality(media, DownloadType.video);
          flow = DuckFlow.ready;
          status = 'Choose video or audio';
        }
      } catch (error) {
        try {
          final playlist = await _api.extractPlaylist(cleanUrl);
          if (playlist.items.isNotEmpty) {
            batchTitle = playlist.title;
            batchPlatform = playlist.platform;
            batchItems = playlist.items;
            selectedType = DownloadType.image;
            quality = 'Best';
            flow = DuckFlow.ready;
            status = 'Choose images to download';
          } else {
            rethrow;
          }
        } catch (fallbackError) {
          if (_shouldUseLockedBrowserFallback(cleanUrl, error) ||
              _shouldUseLockedBrowserFallback(cleanUrl, fallbackError)) {
            _requestLockedBrowser(cleanUrl, _browserPlatformFor(cleanUrl));
            return;
          }
          rethrow;
        }
      }
    }
  }

  Future<void> _playQuack() async {
    try {
      await _quackPlayer.setAsset('quack_duck_sound.mp3');
      await _quackPlayer.play();
    } catch (_) {}
  }

  Future<void> pasteAndExtract() async {
    if (busy) return;
    unawaited(_playQuack());
    busy = true;
    flow = DuckFlow.extracting;
    status = 'Checking link...';
    metadata = null;
    batchItems = null;
    batchTitle = null;
    batchPlatform = null;
    lockedBrowserRequest = null;
    notifyListeners();

    try {
      final url = await _clipboard.readText();
      if (url == null) {
        throw Exception('Copy a public social media link first.');
      }
      await _extractUrlOrBatch(url);
    } catch (error) {
      flow = DuckFlow.error;
      status = _cleanError(error);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> startDownload() async {
    final media = metadata;
    if (media == null || busy) return;
    busy = true;
    flow = DuckFlow.downloading;
    status = 'Downloading...';
    metadata = null;
    notifyListeners();

    try {
      final id = await _api.startDownload(
        url: media.url,
        type: selectedType,
        quality: quality,
        removeMusic: removeMusic,
      );
      final item = DownloadItem(
        id: id,
        url: media.url,
        title: media.title,
        thumbnail: media.thumbnail,
        platform: media.platform,
        quality: quality,
        type: selectedType,
        createdAt: DateTime.now(),
        status: DownloadStatus.queued,
        progress: 0,
        favorite: false,
      );
      await _saveItem(item);
      activeId = id;
      _watchDownload(id, item);
    } catch (error) {
      flow = DuckFlow.error;
      status = _cleanError(error);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> pauseDownload(DownloadItem item) {
    return _controlDownload(item: item, action: 'pause');
  }

  Future<void> resumeDownload(DownloadItem item) async {
    final next = await _controlDownload(item: item, action: 'resume');
    if (next != null && next.status != DownloadStatus.paused) {
      _watchDownload(item.id, next);
    }
  }

  Future<void> cancelDownload(DownloadItem item) {
    return _controlDownload(item: item, action: 'cancel');
  }

  Future<void> deleteDownload(DownloadItem item) async {
    await _files.deleteFile(item.filePath);
    await _store.delete(item.id);
    _downloads = _store.readDownloads();
    if (playerItem?.id == item.id) playerItem = null;
    notifyListeners();
  }

  Future<void> shareDownload(DownloadItem item) =>
      _files.shareFile(item.filePath);

  Future<void> toggleAutoSaveVideos(bool enabled) async {
    autoSaveVideos = enabled;
    await _store.writeAutoSaveVideos(enabled);
    status = enabled ? 'Auto save enabled' : 'Auto save disabled';
    notifyListeners();
  }

  Future<void> saveVideoExternally(DownloadItem item) async {
    await _saveExternally(item, DownloadType.video);
  }

  Future<void> saveAudioExternally(DownloadItem item) async {
    await _saveExternally(item, DownloadType.audio);
  }

  void changeType(DownloadType type) {
    final media = metadata;
    if (media == null) return;
    selectedType = type;
    quality = _firstQuality(media, type);
    notifyListeners();
  }

  void changeQuality(String value) {
    quality = value;
    notifyListeners();
  }

  Future<DownloadItem?> _controlDownload({
    required DownloadItem item,
    required String action,
  }) async {
    if (controlPendingIds.contains(item.id)) return null;
    controlPendingIds.add(item.id);
    notifyListeners();
    try {
      final update = await _api.controlDownload(id: item.id, action: action);
      final next = item.copyWith(
        progress: update.progress,
        status: update.status,
      );
      await _saveItem(next);
      if (action == 'resume' && next.status != DownloadStatus.paused) {
        activeId = item.id;
        flow = DuckFlow.downloading;
        status = 'Downloading...';
      } else if (action == 'resume') {
        status = 'Pausing...';
      } else if (action == 'pause') {
        status = 'Download paused';
        flow = DuckFlow.downloading;
      } else {
        await _store.delete(next.id);
        _downloads = _store.readDownloads();
        if (activeId == item.id) {
          activeId = null;
          flow = DuckFlow.idle;
          status = 'Tap the duck';
        }
      }
      _syncActiveFlow();
      return next;
    } catch (error) {
      flow = DuckFlow.error;
      status = _cleanError(error).contains('Download not found')
          ? 'Restart backend with latest build, then try again.'
          : _cleanError(error);
      return null;
    } finally {
      controlPendingIds.remove(item.id);
      notifyListeners();
    }
  }

  void _watchDownload(String id, DownloadItem baseItem) {
    _api
        .watchDownload(id)
        .listen(
          (update) async {
            var next = baseItem.copyWith(
              progress: update.progress,
              status: update.status == DownloadStatus.completed
                  ? DownloadStatus.processing
                  : update.status,
            );
            await _saveItem(next);

            if (update.status == DownloadStatus.completed) {
              if (update.fileUrl == null) {
                next = next.copyWith(status: DownloadStatus.failed);
                await _saveItem(next);
                flow = DuckFlow.error;
                status = 'Server completed download but returned no file URL.';
              } else {
                try {
                  next = next.copyWith(
                    status: DownloadStatus.processing,
                    progress: 99,
                  );
                  await _saveItem(next);
                  final filePath = await _files.downloadRemoteFile(
                    url: _api.absoluteFileUrl(update.fileUrl!),
                    filename:
                        update.filename ??
                        '${baseItem.title}.${baseItem.type == DownloadType.audio
                            ? 'mp3'
                            : baseItem.type == DownloadType.image
                            ? 'jpg'
                            : 'mp4'}',
                    type: baseItem.type,
                  );
                  next = next.copyWith(
                    filePath: filePath,
                    progress: 100,
                    status: DownloadStatus.completed,
                  );
                  await _saveItem(next);
                  if (next.isVideo && autoSaveVideos) {
                    next = await _trySaveVideoAfterDownload(next);
                  }
                  if (next.type == DownloadType.image) {
                    next = await _trySaveImageAfterDownload(next);
                  }
                  metadata = null;
                  flow = DuckFlow.success;
                  status = next.externalSaveError == null
                      ? next.type == DownloadType.image
                            ? 'Download complete and saved to pictures'
                            : next.isVideo && next.savedToGallery
                            ? 'Download complete and saved to gallery'
                            : 'Download complete'
                      : 'Download complete. Auto save failed.';
                  unawaited(
                    _notifications.showDownloadComplete(
                      id: next.id.hashCode,
                      title: next.title,
                      type: next.type == DownloadType.image
                          ? 'Image'
                          : next.isVideo
                          ? 'Video'
                          : 'Audio',
                    ),
                  );
                } catch (error) {
                  next = next.copyWith(status: DownloadStatus.failed);
                  await _saveItem(next);
                  flow = DuckFlow.error;
                  status =
                      'Failed to save download locally: ${_cleanError(error)}';
                }
              }
            }

            if (update.status == DownloadStatus.failed) {
              await _saveItem(next.copyWith(status: DownloadStatus.failed));
              flow = DuckFlow.error;
              status = _cleanError(update.error ?? 'Download failed.');
              unawaited(
                _notifications.showDownloadFailed(
                  id: next.id.hashCode,
                  title: next.title,
                  error: status,
                ),
              );
            }

            if (update.status == DownloadStatus.paused) {
              await _saveItem(next.copyWith(status: DownloadStatus.paused));
              status = 'Download paused';
              flow = DuckFlow.downloading;
            }

            if (update.status == DownloadStatus.cancelled) {
              await _store.delete(next.id);
              _downloads = _store.readDownloads();
              if (activeId == id) {
                activeId = null;
                flow = DuckFlow.idle;
                status = 'Tap the duck';
              }
            }
            _syncActiveFlow();
            notifyListeners();
          },
          onError: (Object error) {
            flow = DuckFlow.error;
            status = _cleanError(error);
            notifyListeners();
          },
        );
  }

  Future<void> _saveItem(DownloadItem item) async {
    await _store.upsert(item);
    _downloads = _store.readDownloads();
    _syncActiveFlow();
    notifyListeners();
  }

  Future<DownloadItem> _trySaveVideoAfterDownload(DownloadItem item) async {
    try {
      return await _saveVideoItem(item);
    } catch (error) {
      final next = item.copyWith(
        savedToGallery: false,
        externalSaveError: _cleanError(error),
      );
      await _saveItem(next);
      return next;
    }
  }

  Future<DownloadItem> _trySaveImageAfterDownload(DownloadItem item) async {
    try {
      return await _saveImageItem(item);
    } catch (error) {
      final next = item.copyWith(
        savedToGallery: false,
        externalSaveError: _cleanError(error),
      );
      await _saveItem(next);
      return next;
    }
  }

  Future<void> saveImageExternally(DownloadItem item) async {
    await _saveExternally(item, DownloadType.image);
  }

  Future<void> _saveExternally(DownloadItem item, DownloadType type) async {
    if (externalSaveBusy) return;
    externalSaveBusy = true;
    status = type == DownloadType.video
        ? 'Saving to gallery...'
        : type == DownloadType.audio
        ? 'Saving audio...'
        : 'Saving image...';
    notifyListeners();
    try {
      final next = type == DownloadType.video
          ? await _saveVideoItem(item)
          : type == DownloadType.audio
          ? await _saveAudioItem(item)
          : await _saveImageItem(item);
      status = type == DownloadType.video
          ? 'Saved to gallery'
          : type == DownloadType.audio
          ? 'Audio save action complete'
          : 'Image saved to pictures';
      if (activeId == item.id) activeId = next.id;
    } catch (error) {
      final message = _cleanError(error);
      await _saveItem(item.copyWith(externalSaveError: message));
      flow = DuckFlow.error;
      status = message;
    } finally {
      externalSaveBusy = false;
      notifyListeners();
    }
  }

  Future<DownloadItem> _saveVideoItem(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) throw Exception('Video file is not available locally.');
    await _mediaSaver.saveVideo(path: path, filename: _fileNameFor(item));
    final next = item.copyWith(savedToGallery: true, externalSaveError: null);
    await _saveItem(next);
    return next;
  }

  Future<DownloadItem> _saveAudioItem(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) throw Exception('Audio file is not available locally.');
    await _mediaSaver.saveAudio(
      path: path,
      filename: _fileNameFor(item),
      type: item.type,
    );
    final next = item.copyWith(savedToMusic: true, externalSaveError: null);
    await _saveItem(next);
    return next;
  }

  Future<DownloadItem> _saveImageItem(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) throw Exception('Image file is not available locally.');

    final hasPerm = await _permissions.hasMediaImagesPermission();
    if (!hasPerm) {
      final granted = await _permissions.requestMediaImagesPermission();
      if (!granted) {
        throw Exception('Storage permission is required to save images.');
      }
    }

    final ext = item.filePath!.split('.').last.toLowerCase();
    final mimeType = ext == 'png'
        ? 'image/png'
        : ext == 'webp'
        ? 'image/webp'
        : 'image/jpeg';
    await _mediaSaver.saveImage(
      path: path,
      filename: _fileNameFor(item),
      mimeType: mimeType,
    );
    final next = item.copyWith(savedToGallery: true, externalSaveError: null);
    await _saveItem(next);
    return next;
  }

  String _fileNameFor(DownloadItem item) {
    if (item.type == DownloadType.image) {
      final ext = item.filePath?.split('.').last ?? 'jpg';
      return item.title.toLowerCase().endsWith('.$ext')
          ? item.title
          : '${item.title}.$ext';
    }
    final ext = item.isAudio ? 'mp3' : 'mp4';
    return item.title.toLowerCase().endsWith('.$ext')
        ? item.title
        : '${item.title}.$ext';
  }

  Future<void> playItem(DownloadItem item) async {
    if (item.filePath == null) return;
    if (item.isAudio) {
      await audioPlayer.stop();
      playingItem = item;
      notifyListeners();
      try {
        await audioPlayer.setFilePath(item.filePath!);
        await audioPlayer.play();
      } catch (e) {
        playingItem = null;
        status = 'Failed to play audio: $e';
        notifyListeners();
      }
    } else {
      await audioPlayer.stop();
      playingItem = null;
      openPlayer(item);
    }
  }

  void playAudio() {
    audioPlayer.play();
    notifyListeners();
  }

  void pauseAudio() {
    audioPlayer.pause();
    notifyListeners();
  }

  void stopAudio() {
    audioPlayer.stop();
    playingItem = null;
    notifyListeners();
  }

  void seekAudio(Duration position) {
    audioPlayer.seek(position);
    notifyListeners();
  }

  void setAudioSpeed(double speed) {
    audioPlayer.setSpeed(speed);
    notifyListeners();
  }

  void _syncActiveFlow() {
    final active = activeDownloads;
    if (activeId != null && !active.any((item) => item.id == activeId)) {
      activeId = active.isEmpty ? null : active.first.id;
      if (active.isEmpty && flow == DuckFlow.downloading) {
        flow = DuckFlow.idle;
        status = 'Tap the duck';
      }
    }
    if (active.isNotEmpty &&
        (flow == DuckFlow.idle || flow == DuckFlow.success)) {
      activeId ??= active.first.id;
      flow = DuckFlow.downloading;
      status = 'Downloading...';
    }
  }

  String _firstQuality(MediaMetadata media, DownloadType type) {
    if (type == DownloadType.image) {
      final formats = media.qualities;
      if (formats.isEmpty) return 'Original Image';
      // For image metadata yt-dlp returns a single synthetic 'Original Image'
      // entry, but a yt-dlp video extract may still expose video heights. Pick
      // the first label regardless so it survives non-image fallback paths.
      return formats.first.label;
    }
    final formats = type == DownloadType.video
        ? media.qualities
        : media.audioFormats;
    if (formats.isEmpty) {
      return type == DownloadType.audio ? 'Best audio' : 'Best';
    }
    return formats.first.label;
  }

  bool _isImageMetadata(MediaMetadata media) {
    if (media.qualities.isEmpty) return false;
    final imageExts = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};
    for (final format in media.qualities) {
      final ext = format.ext?.toLowerCase();
      final label = format.label.toLowerCase();
      if (ext != null && imageExts.contains(ext)) return true;
      if (label.contains('original image') || label.contains('image')) {
        return true;
      }
    }
    return false;
  }

  bool _looksLikeImageUrl(String url) {
    final lower = url.toLowerCase();
    const exts = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'];
    final cleaned = lower.split('?').first.split('#').first;
    return exts.any(cleaned.endsWith);
  }

  bool _isPublicMediaCandidate(String value) {
    return RegExp(
      r'^https?:\/\/[^\s/$.?#].[^\s]*$',
      caseSensitive: false,
    ).hasMatch(value.trim());
  }

  bool _shouldUseLockedBrowserFallback(String url, Object error) {
    final lowerUrl = url.toLowerCase();
    return lowerUrl.contains('instagram.com') ||
        lowerUrl.contains('threads.net') ||
        lowerUrl.contains('threads.com') ||
        lowerUrl.contains('x.com') ||
        lowerUrl.contains('twitter.com');
  }

  String _browserPlatformFor(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('instagram.com')) return 'Instagram';
    if (lower.contains('threads.net') || lower.contains('threads.com')) return 'Threads';
    if (lower.contains('x.com') || lower.contains('twitter.com')) return 'X';
    return 'Social';
  }

  String _cleanError(Object error) {
    final cleaned = error
        .toString()
        .replaceFirst('Exception: ', '')
        .replaceFirst('WebSocketChannelException: ', '')
        .trim();
    if (cleaned.isEmpty || cleaned == 'null') {
      return 'Download failed. Check the backend logs and try again.';
    }
    return cleaned;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboardOnResume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    premium.removeListener(_premiumChanged);
    _playerStateSubscription.cancel();
    _playerPositionSubscription.cancel();
    _quackPlayer.dispose();
    super.dispose();
  }

  Future<void> _checkClipboardOnResume() async {
    if (!enableClipboardDetection || busy) return;
    try {
      final url = await _clipboard.readText();
      if (url != null && _isPublicMediaCandidate(url)) {
        if (url != _lastDetectedUrl) {
          detectedClipboardUrl = url;
          notifyListeners();
        }
      }
    } catch (_) {}
  }

  void dismissClipboardDetection() {
    _lastDetectedUrl = detectedClipboardUrl;
    detectedClipboardUrl = null;
    notifyListeners();
  }

  Future<void> toggleEnableClipboardDetection(bool enabled) async {
    enableClipboardDetection = enabled;
    await _store.writeEnableClipboardDetection(enabled);
    if (!enabled) {
      detectedClipboardUrl = null;
    }
    notifyListeners();
  }

  Future<void> acceptClipboardDetection() async {
    final url = detectedClipboardUrl;
    if (url == null) return;
    _lastDetectedUrl = url;
    detectedClipboardUrl = null;
    setTab(DuckTab.home);

    if (busy) return;
    busy = true;
    flow = DuckFlow.extracting;
    status = 'Checking link...';
    metadata = null;
    batchItems = null;
    batchTitle = null;
    batchPlatform = null;
    lockedBrowserRequest = null;
    notifyListeners();

    try {
      await _extractUrlOrBatch(url);
    } catch (error) {
      flow = DuckFlow.error;
      status = _cleanError(error);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> extractCustomUrl(String url) async {
    setTab(DuckTab.home);
    if (busy) return;
    busy = true;
    flow = DuckFlow.extracting;
    status = 'Checking link...';
    metadata = null;
    notifyListeners();

    try {
      final media = await _api.extract(url);
      metadata = media;
      if (_isImageMetadata(media) || _looksLikeImageUrl(url)) {
        selectedType = DownloadType.image;
        quality = _firstQuality(media, DownloadType.image);
        flow = DuckFlow.ready;
        status = 'Tap download to save image';
      } else {
        selectedType = DownloadType.video;
        quality = _firstQuality(media, DownloadType.video);
        flow = DuckFlow.ready;
        status = 'Choose video or audio';
      }
    } catch (error) {
      flow = DuckFlow.error;
      status = _cleanError(error);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<MediaMetadata> extractMedia(String url) async {
    try {
      return await _api.extract(url);
    } catch (error) {
      throw Exception(_cleanError(error));
    }
  }

  Future<void> startDownloadFor({
    required MediaMetadata media,
    required DownloadType type,
    required String quality,
    bool removeMusic = false,
  }) async {
    try {
      final id = await _api.startDownload(
        url: media.url,
        type: type,
        quality: quality,
        removeMusic: removeMusic,
      );
      final item = DownloadItem(
        id: id,
        url: media.url,
        title: media.title,
        thumbnail: media.thumbnail,
        platform: media.platform,
        quality: quality,
        type: type,
        createdAt: DateTime.now(),
        status: DownloadStatus.queued,
        progress: 0,
        favorite: false,
      );
      await _saveItem(item);
      activeId = id;
      _watchDownload(id, item);
      notifyListeners();
    } catch (error) {
      throw Exception(_cleanError(error));
    }
  }

  Future<void> updateItemMetadata(
    DownloadItem item, {
    required String title,
    required String artist,
    required String album,
  }) async {
    if (item.isAudio && item.filePath != null) {
      await _files.updateMp3Metadata(
        filePath: item.filePath!,
        title: title,
        artist: artist,
        album: album,
      );
    }
    final next = item.copyWith(title: title, artist: artist, album: album);
    await _saveItem(next);
  }

  Future<PlaylistExtractResponse> extractPlaylist(String url) async {
    try {
      return await _api.extractPlaylist(url);
    } catch (error) {
      throw Exception(_cleanError(error));
    }
  }

  Future<void> startBatchDownload({
    required List<String> urls,
    required DownloadType type,
    required String quality,
    bool removeMusic = false,
    bool forceHybrid = false,
  }) async {
    final itemsByUrl = {
      for (final item in batchItems ?? <PlaylistItem>[]) item.url: item,
    };
    var started = 0;
    var failed = 0;

    for (final url in urls) {
      try {
        final batchItem = itemsByUrl[url];
        final itemType = forceHybrid
            ? (batchItem?.isVideo == true ? DownloadType.video : DownloadType.image)
            : type;
        debugPrint('DEBUG BATCH: url=$url title=${batchItem?.title} isVideo=${batchItem?.isVideo} forceHybrid=$forceHybrid itemType=$itemType');
        if (itemType == DownloadType.image && batchItem?.isPreview == true) {
          throw Exception('Could not access the full-size Instagram image.');
        }
        String title = batchItem?.title ?? '';
        if (title.isEmpty) {
          try {
            final uri = Uri.parse(url);
            final segments = uri.pathSegments.where((s) => s.isNotEmpty);
            if (segments.isNotEmpty) {
              title = segments.last.split('?').first.split('#').first;
              final dot = title.lastIndexOf('.');
              if (dot > 0) title = title.substring(0, dot);
            }
          } catch (_) {}
        }
        if (title.isEmpty) title = url;

        String mediaUrl;
        String? thumbnail;
        String platform;

        if (_looksLikeImageUrl(url) || itemType == DownloadType.image || (itemType == DownloadType.video && batchItem?.isVideo == true)) {
          mediaUrl = url;
          thumbnail = batchItem?.thumbnail ?? url;
          platform = batchPlatform ?? 'Public source';
        } else {
          final media = await _api.extract(url);
          mediaUrl = media.url;
          thumbnail = media.thumbnail;
          platform = media.platform;
        }

        final id = await _api.startDownload(
          url: mediaUrl,
          type: itemType,
          quality: itemType == DownloadType.video ? 'Best' : quality,
          removeMusic: removeMusic,
        );
        final item = DownloadItem(
          id: id,
          url: mediaUrl,
          title: title,
          thumbnail: thumbnail,
          platform: platform,
          quality: quality,
          type: itemType,
          createdAt: DateTime.now(),
          status: DownloadStatus.queued,
          progress: 0,
          favorite: false,
        );
        await _saveItem(item);
        activeId = id;
        _watchDownload(id, item);
        started++;
      } catch (error) {
        failed++;
      }
    }

    final noun = type == DownloadType.image ? 'image' : 'download';
    if (started > 0 && failed > 0) {
      status = 'Started $started ${noun}s, $failed failed';
    } else if (started > 0) {
      status = 'Started $started ${noun}s';
    } else if (failed > 0) {
      status = 'Failed to start $failed ${noun}s';
      flow = DuckFlow.error;
    }
    notifyListeners();
  }

  Future<void> trimDownload(
    DownloadItem item, {
    required double startTime,
    required double endTime,
  }) async {
    if (busy) return;
    busy = true;
    status = 'Trimming file...';
    notifyListeners();

    try {
      final res = await _api.trim(
        downloadId: item.id,
        startTime: startTime,
        endTime: endTime,
      );

      if (item.filePath != null) {
        final oldFile = File(item.filePath!);
        if (await oldFile.exists()) {
          await oldFile.delete();
        }
      }

      final fileUrl = res['fileUrl'] as String;
      final filename = res['filename'] as String;
      final downloadUrl = _api.absoluteFileUrl(fileUrl);

      final newPath = await _files.downloadRemoteFile(
        url: downloadUrl,
        filename: filename,
        type: item.type,
      );

      final next = item.copyWith(
        filePath: newPath,
        quality: item.quality != null ? '${item.quality} (trimmed)' : 'trimmed',
      );
      await _saveItem(next);

      if (playerItem?.id == item.id) {
        playerItem = next;
      }
      status = 'Trimming complete';
    } catch (error) {
      status = _cleanError(error);
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void clearBatch() {
    batchItems = null;
    batchTitle = null;
    batchPlatform = null;
    flow = DuckFlow.idle;
    status = 'Tap the duck';
    notifyListeners();
  }

  Future<void> loadCookiesStatus() async {
    try {
      backendCookies = await _api.getCookies();
      notifyListeners();
    } catch (_) {
      // Ignored: API might be temporarily unreachable on startup
    }
  }

  Future<void> updateCookies(String content) async {
    try {
      backendCookies = await _api.setCookies(content);
      status = 'Cookies updated successfully';
      notifyListeners();
    } catch (e) {
      status = 'Failed to update cookies: $e';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> clearCookies() async {
    try {
      backendCookies = await _api.deleteCookies();
      status = 'Cookies cleared';
      notifyListeners();
    } catch (e) {
      status = 'Failed to clear cookies: $e';
      notifyListeners();
      rethrow;
    }
  }
}
