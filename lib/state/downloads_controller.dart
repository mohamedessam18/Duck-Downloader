import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../constants/asset_paths.dart';
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
import '../services/trim_service.dart';
import '../services/youtube_explode_service.dart';
import '../services/vault_encryption_service.dart';
import '../services/camera_service.dart';
import '../services/conversion_service.dart';
import '../services/cobalt_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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
    YouTubeExplodeService? ytExplode,
    bool initializePremium = true,
    bool initializePlatformServices = true,
  }) : _api = api,
       _clipboard = clipboard,
       _files = files,
       _mediaSaver = mediaSaver,
       _store = store,
       premium = premiumManager,
       _notifications = notificationService ?? NotificationService(),
       _permissions = permissionService ?? PermissionService(),
       _ytExplode = ytExplode ?? YouTubeExplodeService() {
    final initialCookies = _store.readYoutubeCookies();
    if (initialCookies != null) {
      _ytExplode.updateCookies(initialCookies);
    }
    _downloads = _store.readDownloads();
    _videoResumePositions = _store.readVideoResumePositions();
    autoSaveVideos = _store.readAutoSaveVideos();
    enableClipboardDetection = _store.readEnableClipboardDetection();
    backgroundPlaybackEnabled = _store.readBackgroundPlaybackEnabled();
    _playlists = _store.readPlaylists();
    _vaultPin = _store.readVaultPin();
    _decoyVaultPin = _store.readDecoyVaultPin();
    _biometricEnabled = _store.readBiometricEnabled();
    premium.addListener(_premiumChanged);
    if (initializePremium) {
      unawaited(premium.initialize());
    }
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkClipboardOnResume();
    });
    unawaited(_notifications.initialize(onTap: _handleNotificationTap));
    if (initializePlatformServices) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_requestPermissionsSafely());
        unawaited(loadCookiesStatus());
      });
    }
    unawaited(_configureAudioSession());
    _playerStateSubscription = audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed &&
          playingItem != null) {
        if (sleepTimerLabel == 'End of track') {
          cancelSleepTimer();
          return; // Don't auto-advance
        }
        if (_loopMode == LoopMode.one) {
          unawaited(audioPlayer.seek(Duration.zero));
          unawaited(audioPlayer.play());
        } else if (hasNextTrack) {
          unawaited(playNext());
        }
      }
      notifyListeners();
    });
    _playerPositionSubscription = audioPlayer.positionStream.listen((_) {
      notifyListeners();
    });
    _initSharingListener();
  }

  final AudioPlayer audioPlayer = AudioPlayer();
  static const _channel = MethodChannel('duck_downloader/media');
  final AudioPlayer _sfxPlayer = AudioPlayer();
  StreamSubscription? _intentSub;
  bool showAdOnOpen = false;
  late final StreamSubscription<PlayerState> _playerStateSubscription;
  late final StreamSubscription<Duration> _playerPositionSubscription;
  DownloadItem? playingItem;
  List<DownloadItem> _audioQueue = [];
  int _audioQueueIndex = 0;
  List<DownloadItem> _videoQueue = [];
  int _videoQueueIndex = 0;
  LoopMode _loopMode = LoopMode.off;
  bool shuffleEnabled = false;
  Map<String, int> _videoResumePositions = {};
  bool audioBackgroundReady = false;
  Completer<void>? _audioBackgroundCompleter;
  String? _lastQueueSourceKey;
  bool _queueShuffled = false;

  bool get hasNextTrack =>
      _audioQueue.length > 1 &&
      (_loopMode == LoopMode.all || _audioQueueIndex < _audioQueue.length - 1);

  bool get hasPreviousTrack =>
      _audioQueue.length > 1 &&
      (_loopMode == LoopMode.all || _audioQueueIndex > 0);
      
  // Queue management
  List<DownloadItem> get audioQueue => List.unmodifiable(_audioQueue);
  int get audioQueueIndex => _audioQueueIndex;

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex -= 1;
    final item = _audioQueue.removeAt(oldIndex);
    _audioQueue.insert(newIndex, item);
    // Update current index if it was affected
    if (oldIndex == _audioQueueIndex) {
      _audioQueueIndex = newIndex;
    } else if (oldIndex < _audioQueueIndex && newIndex >= _audioQueueIndex) {
      _audioQueueIndex--;
    } else if (oldIndex > _audioQueueIndex && newIndex <= _audioQueueIndex) {
      _audioQueueIndex++;
    }
    notifyListeners();
  }

  void removeFromQueue(int index) {
    if (_audioQueue.length <= 1) return;
    if (index == _audioQueueIndex) return; // Can't remove currently playing
    _audioQueue.removeAt(index);
    if (index < _audioQueueIndex) _audioQueueIndex--;
    notifyListeners();
  }

  void playFromQueue(int index) {
    if (index < 0 || index >= _audioQueue.length) return;
    _audioQueueIndex = index;
    playItem(_audioQueue[index], advanceQueue: true);
  }
      
  bool get hasNextVideo => _videoQueue.length > 1 && _videoQueueIndex < _videoQueue.length - 1;
  bool get hasPreviousVideo => _videoQueue.length > 1 && _videoQueueIndex > 0;
  DownloadItem? get nextVideoItem => hasNextVideo ? _videoQueue[_videoQueueIndex + 1] : null;

  LoopMode get loopMode => _loopMode;

  bool get isAudioPlaying => audioPlayer.playing;
  Duration get audioPosition => audioPlayer.position;
  Duration get audioDuration => audioPlayer.duration ?? Duration.zero;
  PlayerState get audioPlayerState => audioPlayer.playerState;

  // Sleep Timer
  Timer? _sleepTimer;
  DateTime? sleepTimerEndTime;
  String? sleepTimerLabel;

  void setSleepTimer(Duration duration, String label) {
    cancelSleepTimer();
    sleepTimerLabel = label;
    sleepTimerEndTime = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      audioPlayer.pause();
      cancelSleepTimer();
    });
    notifyListeners();
  }

  void setSleepTimerEndOfTrack() {
    cancelSleepTimer();
    sleepTimerLabel = 'End of track';
    sleepTimerEndTime = null; // special marker
    notifyListeners();
    // The actual pause happens in the playerStateStream listener when track completes
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepTimerEndTime = null;
    sleepTimerLabel = null;
    notifyListeners();
  }

  bool get isSleepTimerActive => sleepTimerLabel != null;

  final DuckApiClient _api;
  final DuckClipboardService _clipboard;
  final DuckFileService _files;
  final MediaSaveService _mediaSaver;
  final DownloadStore _store;
  final PremiumManager premium;
  final NotificationService _notifications;
  final PermissionService _permissions;
  final TrimService _trimService = TrimService();
  final YouTubeExplodeService _ytExplode;

  List<DownloadItem> _downloads = [];
  List<Playlist> _playlists = [];
  String? _vaultPin;
  String? _decoyVaultPin;
  bool _biometricEnabled = false;
  bool get isVaultSetup => _vaultPin != null;
  bool get isDecoyVaultSetup => _decoyVaultPin != null;
  bool get biometricEnabled => _biometricEnabled;
  bool isVaultLocked = true;
  bool isDecoySession = false;
  int _failedPinAttempts = 0;
  DownloadItem? lastDownloadedItem;
  bool downloadDirectToVault = false;
  bool isAdultContentBlocked = false;

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
  String? lastAttemptedUrl;
  String quality = 'Best';
  bool busy = false;
  bool _justReturnedFromLockedBrowser = false;
  bool autoSaveVideos = true;
  bool enableClipboardDetection = true;
  bool backgroundPlaybackEnabled = true;
  String? detectedClipboardUrl;
  String? _lastDetectedUrl;
  
  Completer<bool>? _playlistChoiceCompleter;
  bool showPlaylistChoiceDialog = false;
  String? pendingPlaylistUrl;
  bool externalSaveBusy = false;
  String? activeId;
  DownloadItem? playerItem;
  List<DownloadItem>? playerGalleryItems;
  List<DownloadItem>? _audioQueueSource;
  final Set<String> controlPendingIds = {};
  final Map<String, StreamSubscription> _downloadSubscriptions = {};

  void _cancelDownloadSubscription(String id) {
    _downloadSubscriptions[id]?.cancel();
    _downloadSubscriptions.remove(id);
  }

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
  List<DownloadItem> get privateDownloads {
    if (isVaultLocked || isDecoySession) {
      return [];
    }
    final list = _downloads
        .where(
          (item) => item.isPrivate && item.status == DownloadStatus.completed,
        )
        .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

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
      isDecoySession = false;
      _failedPinAttempts = 0;
      notifyListeners();
      return true;
    } else if (pin == _decoyVaultPin) {
      isVaultLocked = false;
      isDecoySession = true;
      _failedPinAttempts = 0;
      notifyListeners();
      return true;
    }
    _failedPinAttempts++;
    if (_failedPinAttempts >= 3) {
      _failedPinAttempts = 0;
      unawaited(VaultCameraService.captureIntruderSelfie());
    }
    return false;
  }

  Future<void> setVaultPin(String pin) async {
    _vaultPin = pin;
    await _store.writeVaultPin(pin);
    notifyListeners();
  }

  Future<void> setDecoyVaultPin(String pin) async {
    _decoyVaultPin = pin;
    await _store.writeDecoyVaultPin(pin);
    notifyListeners();
  }

  Future<void> toggleBiometricEnabled(bool enabled) async {
    _biometricEnabled = enabled;
    await _store.writeBiometricEnabled(enabled);
    notifyListeners();
  }

  void lockVault() {
    isVaultLocked = true;
    isDecoySession = false;
    notifyListeners();
  }

  void unlockVaultBiometric() {
    isVaultLocked = false;
    isDecoySession = false;
    notifyListeners();
  }

  Future<void> toggleFavorite(DownloadItem item) async {
    final next = item.copyWith(favorite: !item.favorite);
    await _saveItem(next);
    if (playingItem?.id == item.id) {
      playingItem = next;
    }
    if (playerItem?.id == item.id) {
      playerItem = next;
    }
    notifyListeners();
  }

  Future<void> moveItemToVault(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) throw Exception('File not available locally.');
    final ext = path.contains('.')
        ? path.split('.').last.toLowerCase()
        : (item.isAudio ? 'mp3' : (item.type == DownloadType.image ? 'jpg' : 'mp4'));
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
    final ext = path.contains('.')
        ? path.split('.').last.toLowerCase()
        : (item.isAudio ? 'mp3' : (item.type == DownloadType.image ? 'jpg' : 'mp4'));
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

  Future<void> importLocalFileToVault(String localPath, DownloadType type) async {
    final file = File(localPath);
    if (!await file.exists()) throw Exception('File does not exist');
    final filename = p.basename(localPath);
    final title = p.basenameWithoutExtension(localPath);

    final root = await getTemporaryDirectory();
    final tempPath = p.join(root.path, filename);
    await file.copy(tempPath);

    final vaultPath = await _files.moveFileToVault(
      currentPath: tempPath,
      filename: filename,
    );

    final item = DownloadItem(
      id: 'local_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      url: 'file://$localPath',
      platform: 'Local Storage',
      type: type,
      status: DownloadStatus.completed,
      progress: 100,
      isPrivate: true,
      filePath: vaultPath,
      createdAt: DateTime.now(),
      favorite: false,
    );

    await _saveItem(item);

    try {
      await file.delete();
    } catch (_) {}

    notifyListeners();
  }

  Future<String> _getEffectiveInputPath(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) throw Exception('File path is null.');
    if (item.isPrivate) {
      String ext = 'mp4';
      if (item.title.toLowerCase().contains('.m4a')) {
        ext = 'm4a';
      } else if (item.title.toLowerCase().contains('.mp3')) {
        ext = 'mp3';
      }
      return await _files.getDecryptedTempPath(
        vaultPath: path,
        originalFilename: 'temp_input.$ext',
      );
    }
    return path;
  }

  Future<void> convertVideoToAudio(DownloadItem item, String format, int bitrate) async {
    final originalPath = item.filePath;
    if (originalPath == null) throw Exception('Video file path is empty.');

    busy = true;
    flow = DuckFlow.extracting;
    status = 'Converting video to audio...';
    notifyListeners();

    String? tempDecryptedPath;
    try {
      final inputPath = await _getEffectiveInputPath(item);
      if (item.isPrivate) {
        tempDecryptedPath = inputPath;
      }

      final audioPath = await ConversionService.convertVideoToAudio(
        inputPath: inputPath,
        format: format,
        bitrate: bitrate,
      );

      final audioItem = DownloadItem(
        id: 'conv_${DateTime.now().millisecondsSinceEpoch}',
        title: '${item.title} (Audio)',
        url: item.url,
        platform: item.platform,
        thumbnail: item.thumbnail,
        quality: '${bitrate}kbps',
        type: DownloadType.audio,
        status: DownloadStatus.completed,
        progress: 100,
        createdAt: DateTime.now(),
        filePath: audioPath,
        isPrivate: item.isPrivate,
        favorite: false,
      );

      if (item.isPrivate) {
        final vaultPath = await _files.moveFileToVault(
          currentPath: audioPath,
          filename: p.basename(audioPath),
        );
        final finalAudioItem = audioItem.copyWith(filePath: vaultPath);
        await _saveItem(finalAudioItem);
      } else {
        await _saveItem(audioItem);
      }

      flow = DuckFlow.success;
      status = 'Conversion complete!';
      unawaited(_notifications.showDownloadComplete(
        id: audioItem.id.hashCode,
        title: audioItem.title,
        type: 'Audio',
        downloadId: audioItem.id,
      ));
    } catch (e) {
      flow = DuckFlow.error;
      status = e.toString().replaceAll('Exception: ', '');
    } finally {
      if (tempDecryptedPath != null) {
        try {
          await File(tempDecryptedPath).delete();
        } catch (_) {}
      }
      busy = false;
      notifyListeners();
    }
  }

  Future<void> createGifFromVideo(DownloadItem item, double startTime, double duration, int width) async {
    final originalPath = item.filePath;
    if (originalPath == null) throw Exception('Video file path is empty.');

    busy = true;
    flow = DuckFlow.extracting;
    status = 'Creating GIF clip...';
    notifyListeners();

    String? tempDecryptedPath;
    try {
      final inputPath = await _getEffectiveInputPath(item);
      if (item.isPrivate) {
        tempDecryptedPath = inputPath;
      }

      final gifPath = await ConversionService.createGifFromVideo(
        inputPath: inputPath,
        startTime: startTime,
        duration: duration,
        width: width,
      );

      final gifItem = DownloadItem(
        id: 'gif_${DateTime.now().millisecondsSinceEpoch}',
        title: '${item.title} (Clip)',
        url: item.url,
        platform: item.platform,
        thumbnail: item.thumbnail,
        quality: '${width}px',
        type: DownloadType.image,
        status: DownloadStatus.completed,
        progress: 100,
        createdAt: DateTime.now(),
        filePath: gifPath,
        isPrivate: item.isPrivate,
        favorite: false,
      );

      if (item.isPrivate) {
        final vaultPath = await _files.moveFileToVault(
          currentPath: gifPath,
          filename: p.basename(gifPath),
        );
        final finalGifItem = gifItem.copyWith(filePath: vaultPath);
        await _saveItem(finalGifItem);
      } else {
        await _saveItem(gifItem);
      }

      flow = DuckFlow.success;
      status = 'GIF created successfully!';
      unawaited(_notifications.showDownloadComplete(
        id: gifItem.id.hashCode,
        title: gifItem.title,
        type: 'Image',
        downloadId: gifItem.id,
      ));
    } catch (e) {
      flow = DuckFlow.error;
      status = e.toString().replaceAll('Exception: ', '');
    } finally {
      if (tempDecryptedPath != null) {
        try {
          await File(tempDecryptedPath).delete();
        } catch (_) {}
      }
      busy = false;
      notifyListeners();
    }
  }

  void shareLastDownloadedItem() {
    if (lastDownloadedItem != null && lastDownloadedItem!.filePath != null) {
      _files.shareFile(lastDownloadedItem!.filePath);
    }
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

  void openPlayer(
    DownloadItem item, {
    List<DownloadItem>? galleryItems,
    List<DownloadItem>? queueItems,
  }) {
    playerItem = item;
    playerGalleryItems = galleryItems;
    _audioQueueSource = queueItems;
    notifyListeners();
  }

  void openPlayerById(String downloadId) {
    for (final item in _downloads) {
      if (item.id == downloadId) {
        if (item.isImage) {
          setTab(DuckTab.images);
        } else if (item.isVideo) {
          setTab(DuckTab.videos);
        } else if (item.isAudio) {
          setTab(DuckTab.audios);
        }
        openPlayer(item);
        return;
      }
    }
  }

  void closePlayer() {
    playerItem = null;
    playerGalleryItems = null;
    _audioQueueSource = null;
    notifyListeners();
  }

  Future<void> _extractUrlOrBatch(String url) async {
    lastAttemptedUrl = url;
    metadata = null;
    batchItems = null;
    batchTitle = null;
    batchPlatform = null;
    lockedBrowserRequest = null;
    lastDownloadedItem = null;

    var cleanUrl = url.trim();


    final isAdult = await _isAdultUrl(cleanUrl);
    if (isAdult) {
      isAdultContentBlocked = true;
      notifyListeners();
      throw Exception('BLOCKED_ADULT_CONTENT');
    }

    final hasVideoAndList = cleanUrl.contains('v=') && (cleanUrl.contains('list=') || cleanUrl.contains('/playlist'));
    var isPlaylist = cleanUrl.contains('list=') || cleanUrl.contains('/playlist');

    if (hasVideoAndList && YouTubeExplodeService.isYouTubeUrl(cleanUrl)) {
      final downloadPlaylist = await _promptPlaylistChoice(cleanUrl);
      if (!downloadPlaylist) {
        cleanUrl = _stripPlaylistParam(cleanUrl);
        isPlaylist = false;
      }
    }
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

      // YouTube playlists: extract on-device via youtube_explode_dart
      if (YouTubeExplodeService.isYouTubePlaylistUrl(cleanUrl)) {
        try {
          final result = await _ytExplode.extractPlaylist(cleanUrl);
          batchTitle = result.title;
          batchPlatform = 'YouTube';
          batchItems = result.items;
          selectedType = DownloadType.video;
          quality = 'Best';
          flow = DuckFlow.ready;
          status = 'Choose videos to download';
          return;
        } catch (e) {
          // Don't fall through to backend for YouTube playlists —
          // the backend will always be bot-checked. Show the error directly.
          throw Exception(
            'Could not load YouTube playlist. It may be private or unavailable.\n'
            'Details: ${e.toString().replaceAll('Exception: ', '')}',
          );
        }
      }

      // Non-YouTube playlist → use backend
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
              // Carousel - show all images as batch
              batchTitle = playlist.title;
              batchPlatform = playlist.platform;
              batchItems = playlist.items;
              selectedType = DownloadType.image;
              quality = 'Best';
              flow = DuckFlow.ready;
              status = 'Choose images to download';
            } else {
              // Single image post - download directly as image
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
      await _sfxPlayer.setAsset(DuckAssets.quackTap);
      await _sfxPlayer.play();
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

  Future<void> extractUrl(String url, {bool fromLockedBrowser = false}) async {
    if (busy) return;
    busy = true;
    _justReturnedFromLockedBrowser = fromLockedBrowser;
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
      _justReturnedFromLockedBrowser = false;
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
      String? cobaltUrl;
      try {
        cobaltUrl = await CobaltService.getDownloadUrl(
          url: media.url,
          type: selectedType,
          qualityLabel: quality,
        );
      } catch (e) {
        debugPrint('Cobalt extraction failed: $e');
      }


      final id = await _api.startDownload(
        url: media.url,
        type: selectedType,
        quality: quality,
        removeMusic: removeMusic,
        premiumNoWatermark: true,
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
        isPrivate: downloadDirectToVault,
      );
      await _saveItem(item);
      activeId = id;
      _watchDownload(id, item);
    } catch (error) {
      flow = DuckFlow.error;
      status = _cleanError(error);
      if (_isLoginRequiredError(error.toString()) && !_justReturnedFromLockedBrowser) {
        _requestLockedBrowser(media.url, _browserPlatformFor(media.url));
        return;
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Downloads media via Cobalt URL directly on-device.
  Future<void> _startCobaltDownload(MediaMetadata media, String downloadUrl) async {
    final ext = selectedType == DownloadType.audio
        ? 'mp3'
        : (selectedType == DownloadType.image ? 'jpg' : 'mp4');
    final itemId = DateTime.now().millisecondsSinceEpoch.toString();

    var item = DownloadItem(
      id: itemId,
      url: media.url,
      title: media.title,
      thumbnail: media.thumbnail,
      platform: media.platform,
      quality: quality,
      type: selectedType,
      createdAt: DateTime.now(),
      status: DownloadStatus.downloading,
      progress: 0,
      favorite: false,
      isPrivate: downloadDirectToVault,
    );
    await _saveItem(item);
    activeId = itemId;

    try {
      final filePath = await _ytExplode.downloadStream(
        streamUrl: downloadUrl,
        title: media.title,
        type: selectedType,
        ext: ext,
        onProgress: (received, total) async {
          if (total <= 0) return;
          final progress = ((received / total) * 100).clamp(0, 100).toInt();
          final updated = item.copyWith(
            progress: progress,
            status: DownloadStatus.downloading,
          );
          await _saveItem(updated);
          notifyListeners();
        },
      );

      if (item.isPrivate) {
        final vaultPath = await _files.moveFileToVault(
          currentPath: filePath,
          filename: p.basename(filePath),
        );
        item = item.copyWith(
          filePath: vaultPath,
          progress: 100,
          status: DownloadStatus.completed,
        );
        await _saveItem(item);
      } else {
        item = item.copyWith(
          filePath: filePath,
          progress: 100,
          status: DownloadStatus.completed,
        );
        await _saveItem(item);

        if (autoSaveVideos) {
          item = await _trySaveMediaAfterDownload(item);
        }
      }

      lastDownloadedItem = item;
      flow = DuckFlow.success;
      status = ((item.isVideo && item.savedToGallery) || (item.isAudio && item.savedToMusic))
          ? 'Download complete and saved externally'
          : 'Download complete';

      unawaited(_notifications.showDownloadComplete(
        id: item.id.hashCode,
        title: item.title,
        type: item.isVideo ? 'Video' : 'Audio',
        downloadId: item.id,
      ));
    } catch (error) {
      item = item.copyWith(status: DownloadStatus.failed);
      await _saveItem(item);
      debugPrint('Cobalt download failed, falling back: $error');

      // Remove the failed Cobalt item to prevent duplicates
      await _store.delete(itemId);
      _downloads = _store.readDownloads();

      // Trigger fallback download
      final isYouTube = media.platform.toLowerCase() == 'youtube';
      if (isYouTube) {
        await _startYouTubeExplodeDownload(media);
      } else {
        final id = await _api.startDownload(
          url: media.url,
          type: selectedType,
          quality: quality,
          removeMusic: removeMusic,
          premiumNoWatermark: true,
        );
        final fallbackItem = DownloadItem(
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
          isPrivate: downloadDirectToVault,
        );
        await _saveItem(fallbackItem);
        activeId = id;
        _watchDownload(id, fallbackItem);
      }
    }
  }

  /// Downloads a YouTube stream URL directly on-device using YouTubeExplodeService.
  Future<void> _startYouTubeExplodeDownload(MediaMetadata media) async {
    // Search in the correct format pool based on selectedType:
    // - Audio downloads must use audioFormats (audio-only streams)
    // - Video downloads use qualities (muxed or video-only)
    // Mixing both lists caused video stream URLs to be used for audio.
    final formatPool = selectedType == DownloadType.audio
        ? media.audioFormats
        : media.qualities;
    final allFormats = [...media.qualities, ...media.audioFormats];

    FormatInfo format;
    if (formatPool.isNotEmpty) {
      format = formatPool.firstWhere(
        (f) => f.label == quality || f.id == quality,
        orElse: () => formatPool.first,
      );
    } else {
      // fallback: search everywhere
      format = allFormats.firstWhere(
        (f) => f.label == quality || f.id == quality,
        orElse: () => allFormats.isNotEmpty
            ? allFormats.first
            : const FormatInfo(id: '', label: 'Best', ext: 'mp4'),
      );
    }

    // For audio: default to webm (YouTube's native Opus container) so the
    // transcode step always fires and produces a playable .m4a
    final ext = format.ext ?? (selectedType == DownloadType.audio ? 'webm' : 'mp4');
    final itemId = DateTime.now().millisecondsSinceEpoch.toString();

    var item = DownloadItem(
      id: itemId,
      url: media.url,
      title: media.title,
      thumbnail: media.thumbnail,
      platform: media.platform,
      quality: format.label,
      type: selectedType,
      createdAt: DateTime.now(),
      status: DownloadStatus.downloading,
      progress: 0,
      favorite: false,
      isPrivate: downloadDirectToVault,
    );
    await _saveItem(item);
    activeId = itemId;

    try {
      String filePath;

      if (selectedType == DownloadType.audio) {
        // ── Audio: use native youtube_explode_dart stream client ─────────────
        // Re-fetches a fresh manifest at download time (no expired URLs).
        // The library handles all YouTube auth headers/cookies internally.
        filePath = await _ytExplode.downloadAudioNative(
          videoUrl: media.url,
          title: media.title,
          onProgress: (received, total) async {
            if (total <= 0) return;
            final progress = ((received / total) * 99).clamp(0, 99).toInt();
            final updated = item.copyWith(
              progress: progress,
              status: DownloadStatus.downloading,
            );
            await _saveItem(updated);
            notifyListeners();
          },
          onTranscoding: () async {
            status = 'Converting to M4A...';
            final updated = item.copyWith(
              progress: 99,
              status: DownloadStatus.processing,
            );
            await _saveItem(updated);
            notifyListeners();
          },
        );
      } else {
        // ── Video: use native youtube_explode_dart download client ────────────
        // This re-fetches a fresh manifest, decrypts signature throttling,
        // and merges video + audio via FFmpeg if it's a high-quality video-only stream.
        filePath = await _ytExplode.downloadVideoNative(
          videoUrl: media.url,
          title: media.title,
          preferredHeight: format.height,
          preferredExt: format.ext,
          onProgress: (received, total) async {
            if (total <= 0) return;
            final progress = ((received / total) * 99).clamp(0, 99).toInt();
            final updated = item.copyWith(
              progress: progress,
              status: DownloadStatus.downloading,
            );
            await _saveItem(updated);
            notifyListeners();
          },
        );
      }

      if (item.isPrivate) {
        final vaultPath = await _files.moveFileToVault(
          currentPath: filePath,
          filename: p.basename(filePath),
        );
        item = item.copyWith(
          filePath: vaultPath,
          progress: 100,
          status: DownloadStatus.completed,
        );
        await _saveItem(item);
      } else {
        item = item.copyWith(
          filePath: filePath,
          progress: 100,
          status: DownloadStatus.completed,
        );
        await _saveItem(item);

        if (autoSaveVideos) {
          item = await _trySaveMediaAfterDownload(item);
        }
      }

      lastDownloadedItem = item;
      flow = DuckFlow.success;
      status = ((item.isVideo && item.savedToGallery) || (item.isAudio && item.savedToMusic))
          ? 'Download complete and saved externally'
          : 'Download complete';

      unawaited(_notifications.showDownloadComplete(
        id: item.id.hashCode,
        title: item.title,
        type: item.isVideo ? 'Video' : 'Audio',
        downloadId: item.id,
      ));
    } catch (error) {
      item = item.copyWith(status: DownloadStatus.failed);
      await _saveItem(item);
      flow = DuckFlow.error;
      status = 'YouTube download failed: ${_cleanError(error)}';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Downloads a YouTube URL on-device during batch/playlist download.
  Future<void> _startYouTubeExplodeBatchDownload({
    required String url,
    required String title,
    required String? thumbnail,
    required DownloadType type,
  }) async {
    // 1. Extract metadata on-device to get streams
    final ytMeta = await _ytExplode.extractMetadata(url);
    if (ytMeta == null || ytMeta.qualities.isEmpty) {
      throw Exception('Could not extract streams for YouTube video.');
    }

    // 2. Select first quality format
    final allFormats = type == DownloadType.video ? ytMeta.qualities : ytMeta.audioFormats;
    if (allFormats.isEmpty) {
      throw Exception('No compatible quality format found.');
    }
    final format = allFormats.first;
    final ext = format.ext ?? (type == DownloadType.audio ? 'webm' : 'mp4');

    // 3. Create download item
    final itemId = '${DateTime.now().millisecondsSinceEpoch}_${url.hashCode}';
    var item = DownloadItem(
      id: itemId,
      url: url,
      title: title.isNotEmpty ? title : ytMeta.title,
      thumbnail: thumbnail ?? ytMeta.thumbnail,
      platform: 'YouTube',
      quality: format.label,
      type: type,
      createdAt: DateTime.now(),
      status: DownloadStatus.downloading,
      progress: 0,
      favorite: false,
    );
    await _saveItem(item);

    // 4. Download directly on-device in background
    unawaited(() async {
      try {
        String filePath;
        if (type == DownloadType.audio) {
          // Native youtube_explode_dart stream client — handles auth internally
          filePath = await _ytExplode.downloadAudioNative(
            videoUrl: url,
            title: item.title,
            onProgress: (received, total) async {
              if (total <= 0) return;
              final progress = ((received / total) * 99).clamp(0, 99).toInt();
              final updated = item.copyWith(
                progress: progress,
                status: DownloadStatus.downloading,
              );
              await _saveItem(updated);
              notifyListeners();
            },
            onTranscoding: () async {
              final updated = item.copyWith(
                progress: 99,
                status: DownloadStatus.processing,
              );
              await _saveItem(updated);
              notifyListeners();
            },
          );
        } else {
          filePath = await _ytExplode.downloadVideoNative(
            videoUrl: url,
            title: item.title,
            preferredHeight: format.height,
            preferredExt: 'mp4',
            onProgress: (received, total) async {
              if (total <= 0) return;
              final progress = ((received / total) * 99).clamp(0, 99).toInt();
              final updated = item.copyWith(
                progress: progress,
                status: DownloadStatus.downloading,
              );
              await _saveItem(updated);
              notifyListeners();
            },
          );
        }
        item = item.copyWith(
          filePath: filePath,
          progress: 100,
          status: DownloadStatus.completed,
        );
        await _saveItem(item);

        if (autoSaveVideos) {
          item = await _trySaveMediaAfterDownload(item);
        }

        unawaited(_notifications.showDownloadComplete(
          id: item.id.hashCode,
          title: item.title,
          type: item.isVideo ? 'Video' : 'Audio',
          downloadId: item.id,
        ));
        notifyListeners();
      } catch (e) {
        final failedItem = item.copyWith(
          status: DownloadStatus.failed,
          progress: 0,
        );
        await _saveItem(failedItem);
        unawaited(_notifications.showDownloadFailed(
          id: item.id.hashCode,
          title: item.title,
          error: e.toString().replaceAll('Exception: ', ''),
        ));
        notifyListeners();
      }
    }());
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

  Future<void> cancelDownload(DownloadItem item) async {
    _cancelDownloadSubscription(item.id);
    await _controlDownload(item: item, action: 'cancel');
  }

  Future<void> deleteDownload(DownloadItem item) async {
    _cancelDownloadSubscription(item.id);
    await _files.deleteFile(item.filePath);
    await _store.delete(item.id);
    _downloads = _store.readDownloads();
    if (playerItem?.id == item.id) playerItem = null;
    notifyListeners();
  }

  Future<void> shareDownload(DownloadItem item) =>
      _files.shareFile(item.filePath);

  Future<void> cutAndSetAsRingtone(
    DownloadItem item, {
    required double startTime,
    required double endTime,
  }) async {
    if (busy) return;

    if (!Platform.isAndroid) {
      throw Exception('Ringtones can only be set programmatically on Android devices.');
    }

    final bool canWrite = await _channel.invokeMethod<bool>('canWriteSettings') ?? false;
    if (!canWrite) {
      await _channel.invokeMethod<void>('requestWriteSettingsPermission');
      throw Exception('Permission required: Please enable "Allow modifying system settings" in Android Settings, then try again.');
    }

    busy = true;
    status = 'Preparing ringtone...';
    notifyListeners();

    String? inputPath;
    try {
      final info = await _getEffectivePathAndFileName(item);
      inputPath = info['path']!;

      final root = await getApplicationDocumentsDirectory();
      final folder = Directory(p.join(root.path, 'Duck Downloader', 'Ringtones'));
      await folder.create(recursive: true);

      final safeName = '${item.id}_ringtone.mp3';
      final finalPath = p.join(folder.path, safeName);
      final finalFile = File(finalPath);

      if (await finalFile.exists()) {
        try {
          await finalFile.delete();
        } catch (_) {}
      }

      final isFullAudio = startTime <= 0.2 && (endTime - startTime) >= 29.5;
      if (isFullAudio) {
        // Fast direct copy without invoking FFmpeg
        await File(inputPath).copy(finalPath);
      } else {
        status = 'Trimming audio...';
        notifyListeners();

        try {
          final trimmedTempPath = await _trimService.trimLocalFile(
            inputPath: inputPath,
            startSec: startTime,
            endSec: endTime,
            type: DownloadType.audio,
          );
          final tempFile = File(trimmedTempPath);
          if (await tempFile.exists()) {
            await tempFile.copy(finalPath);
            try {
              await tempFile.delete();
            } catch (_) {}
          } else {
            await File(inputPath).copy(finalPath);
          }
        } catch (e) {
          debugPrint('FFmpeg trim fallback to direct copy: $e');
          await File(inputPath).copy(finalPath);
        }
      }

      status = 'Setting system ringtone...';
      notifyListeners();

      final bool success = await _channel.invokeMethod<bool>('setRingtone', {
        'path': finalPath,
        'title': item.title,
      }) ?? false;

      if (success) {
        status = 'Ringtone set successfully!';
      } else {
        throw Exception('Could not register ringtone in Android system database.');
      }
    } catch (e) {
      status = 'Error: ${e.toString()}';
      rethrow;
    } finally {
      if (item.isPrivate && inputPath != null && inputPath != item.filePath) {
        try {
          await File(inputPath).delete();
        } catch (_) {}
      }
      busy = false;
      notifyListeners();
    }
  }

  Future<void> toggleAutoSaveVideos(bool enabled) async {
    autoSaveVideos = enabled;
    await _store.writeAutoSaveVideos(enabled);
    status = enabled ? 'Auto save enabled' : 'Auto save disabled';
    notifyListeners();
  }

  Future<void> toggleBackgroundPlayback(bool enabled) async {
    backgroundPlaybackEnabled = enabled;
    await _store.writeBackgroundPlaybackEnabled(enabled);
    status = enabled ? 'Background playback enabled' : 'Background playback disabled';
    notifyListeners();
  }

  void toggleClipboardDetection(bool value) {
    enableClipboardDetection = value;
    notifyListeners();
  }

  void toggleBackgroundPlaybackEnabled(bool value) {
    toggleBackgroundPlayback(value);
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
        _cancelDownloadSubscription(item.id);
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
    _cancelDownloadSubscription(id);
    _downloadSubscriptions[id] = _api
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
              _cancelDownloadSubscription(id);
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
                  if (next.isPrivate) {
                    final vaultPath = await _files.moveFileToVault(
                      currentPath: filePath,
                      filename: p.basename(filePath),
                    );
                    next = next.copyWith(
                      filePath: vaultPath,
                      progress: 100,
                      status: DownloadStatus.completed,
                    );
                    await _saveItem(next);
                  } else {
                    next = next.copyWith(
                      filePath: filePath,
                      progress: 100,
                      status: DownloadStatus.completed,
                    );
                    await _saveItem(next);
                    if (autoSaveVideos) {
                      next = await _trySaveMediaAfterDownload(next);
                    }
                  }

                  lastDownloadedItem = next;
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
                      downloadId: next.id,
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
              _cancelDownloadSubscription(id);
              final errText = update.error ?? '';
              final isLoginRequired = _isLoginRequiredError(errText);

              await _saveItem(next.copyWith(status: DownloadStatus.failed));
              flow = DuckFlow.error;
              status = _cleanError(errText.isNotEmpty ? errText : 'Download failed.');

              if (isLoginRequired && !_justReturnedFromLockedBrowser) {
                _requestLockedBrowser(
                  baseItem.url,
                  _browserPlatformFor(baseItem.url),
                );
                return;
              }

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
              _cancelDownloadSubscription(id);
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
            _cancelDownloadSubscription(id);
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

  Future<DownloadItem> _trySaveMediaAfterDownload(DownloadItem item) async {
    try {
      if (item.isVideo) {
        return await _saveVideoItem(item);
      } else if (item.isAudio) {
        return await _saveAudioItem(item);
      } else if (item.type == DownloadType.image) {
        return await _saveImageItem(item);
      }
      return item;
    } catch (error) {
      final next = item.copyWith(
        savedToGallery: false,
        savedToMusic: false,
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

  Future<Map<String, String>> getEffectivePathAndFileName(DownloadItem item) =>
      _getEffectivePathAndFileName(item);

  Future<Map<String, String>> _getEffectivePathAndFileName(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) throw Exception('File is not available.');

    String fileName = _fileNameFor(item);
    String effectivePath = path;

    if (item.isPrivate) {
      effectivePath = await _files.getDecryptedTempPath(
        vaultPath: path,
        originalFilename: fileName,
      );
    }
    return {
      'path': effectivePath,
      'filename': fileName,
    };
  }

  Future<DownloadItem> _saveVideoItem(DownloadItem item) async {
    final info = await _getEffectivePathAndFileName(item);
    final path = info['path']!;
    final filename = info['filename']!;
    try {
      await _mediaSaver.saveVideo(path: path, filename: filename);
    } finally {
      if (item.isPrivate) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
    final next = item.copyWith(savedToGallery: true, externalSaveError: null);
    await _saveItem(next);
    return next;
  }

  Future<DownloadItem> _saveAudioItem(DownloadItem item) async {
    final info = await _getEffectivePathAndFileName(item);
    final path = info['path']!;
    final filename = info['filename']!;
    try {
      await _mediaSaver.saveAudio(
        path: path,
        filename: filename,
        type: item.type,
      );
    } finally {
      if (item.isPrivate) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
    final next = item.copyWith(savedToMusic: true, externalSaveError: null);
    await _saveItem(next);
    return next;
  }

  Future<DownloadItem> _saveImageItem(DownloadItem item) async {
    final info = await _getEffectivePathAndFileName(item);
    final path = info['path']!;
    final filename = info['filename']!;

    final ext = filename.split('.').last.toLowerCase();
    final mimeType = ext == 'png'
        ? 'image/png'
        : ext == 'webp'
        ? 'image/webp'
        : ext == 'gif'
        ? 'image/gif'
        : 'image/jpeg';

    try {
      try {
        await _mediaSaver.saveImage(
          path: path,
          filename: filename,
          mimeType: mimeType,
        );
      } catch (e) {
        // Fallback for older Android devices or strict security policies: request permission and retry
        final hasPerm = await _permissions.hasMediaImagesPermission();
        if (!hasPerm) {
          final granted = await _permissions.requestMediaImagesPermission();
          if (!granted) {
            throw Exception('Storage permission is required to save images: $e');
          }
        }
        await _mediaSaver.saveImage(
          path: path,
          filename: filename,
          mimeType: mimeType,
        );
      }
    } finally {
      if (item.isPrivate) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
    final next = item.copyWith(savedToGallery: true, externalSaveError: null);
    await _saveItem(next);
    return next;
  }

  String _fileNameFor(DownloadItem item) {
    if (item.type == DownloadType.image) {
      String ext = 'jpg';
      if (item.title.toLowerCase().contains('.png')) {
        ext = 'png';
      } else if (item.title.toLowerCase().contains('.webp')) {
        ext = 'webp';
      } else if (item.title.toLowerCase().contains('.gif')) {
        ext = 'gif';
      } else if (!item.isPrivate) {
        final pathExt = item.filePath?.split('.').last ?? 'jpg';
        if (pathExt != 'enc') ext = pathExt;
      }
      
      final cleanTitle = item.title
          .replaceAll(RegExp(r'\.(jpg|jpeg|png|webp|gif)$', caseSensitive: false), '');
      return '$cleanTitle.$ext';
    }
    
    if (item.isAudio) {
      String ext = 'mp3';
      if (item.title.toLowerCase().contains('.m4a')) {
        ext = 'm4a';
      } else if (!item.isPrivate) {
        final pathExt = item.filePath?.split('.').last ?? 'mp3';
        if (pathExt != 'enc') ext = pathExt;
      }
      final cleanTitle = item.title
          .replaceAll(RegExp(r'\.(mp3|m4a)$', caseSensitive: false), '');
      return '$cleanTitle.$ext';
    }

    String ext = 'mp4';
    if (!item.isPrivate) {
      final pathExt = item.filePath?.split('.').last ?? 'mp4';
      if (pathExt != 'enc') ext = pathExt;
    }
    final cleanTitle = item.title
        .replaceAll(RegExp(r'\.mp4$', caseSensitive: false), '');
    return '$cleanTitle.$ext';
  }

  Future<void> markAudioBackgroundReady() async {
    if (audioBackgroundReady) return;
    audioBackgroundReady = true;
    if (_audioBackgroundCompleter != null && !_audioBackgroundCompleter!.isCompleted) {
      _audioBackgroundCompleter!.complete();
    }
    notifyListeners();
  }

  Future<void> _ensureAudioBackgroundReady() async {
    if (audioBackgroundReady) return;
    _audioBackgroundCompleter ??= Completer<void>();
    try {
      await _audioBackgroundCompleter!.future.timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Uri? _artUriFor(DownloadItem item) {
    final thumb = item.thumbnail;
    if (thumb == null || thumb.isEmpty) return null;
    if (thumb.startsWith('http://') || thumb.startsWith('https://')) {
      return Uri.tryParse(thumb);
    }
    if (Platform.isIOS) {
      // iOS nowplayingd sandbox restricts reading local app files out-of-process.
      // Returning null avoids breaking lock screen/Dynamic Island controls.
      return null;
    }
    try {
      final file = File(thumb);
      if (file.existsSync()) {
        return file.uri;
      }
    } catch (_) {}
    return null;
  }

  Future<void> playItem(DownloadItem item, {bool advanceQueue = false}) async {
    if (item.filePath == null) return;
    if (item.isAudio) {
      if (!advanceQueue) {
        _buildAudioQueue(item);
      }
      await audioPlayer.stop();
      playingItem = item;
      playerItem = item;
      notifyListeners();
      try {
        await _ensureAudioBackgroundReady();
        if (audioBackgroundReady) {
          await audioPlayer.setAudioSource(
            AudioSource.file(
              item.filePath!,
              tag: MediaItem(
                id: item.id,
                title: item.title,
                artist: item.artist ?? item.platform,
                album: item.album,
                artUri: _artUriFor(item),
              ),
            ),
          );
        } else {
          await audioPlayer.setFilePath(item.filePath!);
        }
        await audioPlayer.setLoopMode(_loopMode);
        await audioPlayer.play();
      } catch (e) {
        try {
          await audioPlayer.setFilePath(item.filePath!);
          await audioPlayer.play();
        } catch (fallbackError) {
          playingItem = null;
          status = 'Failed to play audio: $fallbackError';
          notifyListeners();
        }
      }
    } else {
      await audioPlayer.stop();
      playingItem = null;
      openPlayer(item);
    }
  }

  void _buildAudioQueue(DownloadItem item, {bool forceReshuffle = false}) {
    final source = _audioQueueSource ?? audios;
    final sourceKey = source.map((entry) => entry.id).join('|');
    final sourceChanged = sourceKey != _lastQueueSourceKey;
    _lastQueueSourceKey = sourceKey;

    _audioQueue =
        source.where((entry) => entry.filePath != null && entry.isAudio).toList();
    _audioQueueIndex = _audioQueue.indexWhere((entry) => entry.id == item.id);
    if (_audioQueueIndex < 0) {
      _audioQueue = [item];
      _audioQueueIndex = 0;
    }

    if (shuffleEnabled && _audioQueue.length > 1) {
      if (forceReshuffle || (sourceChanged && !_queueShuffled)) {
        final current = _audioQueue.removeAt(_audioQueueIndex);
        _audioQueue.shuffle();
        _audioQueue.insert(0, current);
        _audioQueueIndex = 0;
        _queueShuffled = true;
      }
    } else {
      _queueShuffled = false;
    }
  }

  Future<void> playNext() async {
    if (!hasNextTrack || _audioQueue.isEmpty) return;
    if (_audioQueueIndex < _audioQueue.length - 1) {
      _audioQueueIndex++;
    } else if (_loopMode == LoopMode.all) {
      _audioQueueIndex = 0;
    } else {
      return;
    }
    await playItem(_audioQueue[_audioQueueIndex], advanceQueue: true);
  }

  Future<void> playPrevious() async {
    if (_audioQueue.isEmpty) return;
    if (audioPlayer.position.inSeconds > 3) {
      await audioPlayer.seek(Duration.zero);
      notifyListeners();
      return;
    }
    if (!hasPreviousTrack) return;
    if (_audioQueueIndex > 0) {
      _audioQueueIndex--;
    } else if (_loopMode == LoopMode.all) {
      _audioQueueIndex = _audioQueue.length - 1;
    } else {
      return;
    }
    await playItem(_audioQueue[_audioQueueIndex], advanceQueue: true);
  }

  void buildVideoQueue(DownloadItem item) {
    final source = playerGalleryItems ?? videos;
    _videoQueue = source.where((entry) => entry.filePath != null && entry.isVideo).toList();
    _videoQueueIndex = _videoQueue.indexWhere((entry) => entry.id == item.id);
    if (_videoQueueIndex < 0) {
      _videoQueue = [item];
      _videoQueueIndex = 0;
    }
  }

  void playNextVideo() {
    if (!hasNextVideo) return;
    _videoQueueIndex++;
    openPlayer(_videoQueue[_videoQueueIndex], galleryItems: playerGalleryItems, queueItems: _audioQueueSource);
  }

  void playPreviousVideo() {
    if (!hasPreviousVideo) return;
    _videoQueueIndex--;
    openPlayer(_videoQueue[_videoQueueIndex], galleryItems: playerGalleryItems, queueItems: _audioQueueSource);
  }

  Future<void> toggleShuffle() async {
    shuffleEnabled = !shuffleEnabled;
    if (playingItem != null) {
      _buildAudioQueue(playingItem!, forceReshuffle: shuffleEnabled);
    }
    notifyListeners();
  }

  Future<void> toggleLoopMode() async {
    _loopMode = switch (_loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await audioPlayer.setLoopMode(_loopMode);
    notifyListeners();
  }

  Duration videoResumePosition(String id) {
    final ms = _videoResumePositions[id];
    if (ms == null || ms <= 0) return Duration.zero;
    return Duration(milliseconds: ms);
  }

  void saveVideoResumePosition(String id, Duration position) {
    final ms = position.inMilliseconds;
    if (ms <= 0) return;
    final previous = _videoResumePositions[id];
    if (previous != null && (ms - previous).abs() < 3000) return;
    _videoResumePositions[id] = ms;
    unawaited(_store.writeVideoResumePosition(id, ms));
  }

  Future<void> _requestPermissionsSafely() async {
    try {
      await _permissions.requestAllRequiredPermissions();
    } catch (error) {
      debugPrint('Permission request failed: $error');
    }
  }

  double? _preDuckVolume;

  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      await session.setActive(true);

      // 1. Auto-pause on headphone disconnect
      session.becomingNoisyEventStream.listen((_) {
        audioPlayer.pause();
        // Also pause video if playing
        // The video player in duck_player_overlay will handle this via lifecycle
      });

      // 2. Handle phone calls and system interruptions
      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              audioPlayer.pause();
              break;
            case AudioInterruptionType.duck:
              _preDuckVolume = audioPlayer.volume;
              audioPlayer.setVolume(audioPlayer.volume * 0.2);
              break;
          }
        } else {
          // Interruption ended
          switch (event.type) {
            case AudioInterruptionType.pause:
              audioPlayer.play();
              break;
            case AudioInterruptionType.duck:
              audioPlayer.setVolume(_preDuckVolume ?? 1.0);
              _preDuckVolume = null;
              break;
            case AudioInterruptionType.unknown:
              break;
          }
        }
      });
    } catch (_) {}
  }

  void _handleNotificationTap(String? payload) {
    if (payload == null || payload.isEmpty) return;
    openPlayerById(payload);
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

  // ── Background Video Audio ───────────────────────────────────────────────
  // When a video is playing and the screen locks / app is backgrounded,
  // we hand off the audio to just_audio so it continues in the background
  // with lock screen controls. On return, the video player resumes.

  bool _backgroundVideoActive = false;
  bool get isBackgroundVideoActive => _backgroundVideoActive;

  /// Starts playing the audio track of a video file in the background
  /// (via just_audio_background) so audio continues when screen is locked.
  ///
  /// [item] — the video DownloadItem
  /// [position] — current playback position to seek to
  /// Starts background audio playback of a video item at the specified position.
  /// Pre-loads the video file into just_audio at volume 0 so that when the
  /// screen locks we only need to unmute — no loading delay at all.
  /// Call this right after the video player starts playing.
  Future<void> preloadBackgroundAudio(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) return;
    try {
      if (!audioBackgroundReady) {
        await _ensureAudioBackgroundReady();
      }

      await audioPlayer.setVolume(0.0); // silent — video provides audio

      await audioPlayer.setAudioSource(
        AudioSource.file(
          path,
          tag: MediaItem(
            id: '${item.id}_bg',
            title: item.title,
            artist: item.platform,
            artUri: _artUriFor(item),
          ),
        ),
      );

      // Don't play yet — we'll start it in sync when the video plays.
      _backgroundVideoPreloaded = true;
      playingItem = item;
    } catch (e) {
      _backgroundVideoPreloaded = false;
      debugPrint('Failed to preload background audio: $e');
    }
  }

  bool _backgroundVideoPreloaded = false;

  /// Activates the pre-loaded background audio player by seeking to the
  /// video's current position, unmuting, and starting playback.
  /// Because the audio source is already loaded, this is nearly instant.
  Future<void> activateBackgroundAudio(Duration position) async {
    if (!_backgroundVideoPreloaded) return;
    if (_backgroundVideoActive) return;
    try {
      _backgroundVideoActive = true;
      await audioPlayer.seek(position);
      await audioPlayer.setVolume(1.0); // unmute — instant!
      await audioPlayer.play();
      notifyListeners();
    } catch (e) {
      _backgroundVideoActive = false;
      debugPrint('Failed to activate background audio: $e');
    }
  }

  /// Deactivates background audio when the video player resumes.
  /// Mutes and pauses instead of stopping, so the source stays loaded
  /// for the next screen lock (no re-loading needed).
  Future<void> deactivateBackgroundAudio() async {
    if (!_backgroundVideoActive) return;
    _backgroundVideoActive = false;
    await audioPlayer.setVolume(0.0); // mute — instant
    await audioPlayer.pause();        // pause, don't stop (keeps source loaded)
    notifyListeners();
  }

  /// Fully stops and releases the background audio. Call this only when
  /// the player overlay is being disposed / closed.
  Future<void> stopBackgroundVideoAudio() async {
    _backgroundVideoActive = false;
    _backgroundVideoPreloaded = false;
    playingItem = null;
    await audioPlayer.stop();
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

  bool _looksLikeVideoUrl(String url) {
    final lower = url.toLowerCase();
    const exts = ['.mp4', '.mov', '.webm', '.avi', '.mkv', '.3gp'];
    final cleaned = lower.split('?').first.split('#').first;
    return exts.any(cleaned.endsWith);
  }

  bool _isPublicMediaCandidate(String value) {
    return RegExp(
      r'^https?:\/\/[^\s/$.?#].[^\s]*$',
      caseSensitive: false,
    ).hasMatch(value.trim());
  }

  bool _isLoginRequiredError(String error) {
    final lower = error.toLowerCase();
    return lower.contains('login') ||
        lower.contains('sign in') ||
        lower.contains('sign-in') ||
        lower.contains('confirm you are not a bot') ||
        lower.contains('captcha') ||
        lower.contains('cookies') ||
        lower.contains('private video') ||
        lower.contains('requires authentication') ||
        lower.contains('members-only') ||
        lower.contains('membership') ||
        lower.contains('joined');
  }

  bool _shouldUseLockedBrowserFallback(String url, Object error) {
    // If we already tried the locked browser once, do NOT loop back into it.
    // Show an error instead so the user understands the server limitation.
    if (_justReturnedFromLockedBrowser) return false;
    final lowerUrl = url.toLowerCase();
    
    final isYouTube = lowerUrl.contains('youtube.com') || lowerUrl.contains('youtu.be');
    if (isYouTube) {
      final errStr = error.toString().toLowerCase();
      return _isLoginRequiredError(errStr) || 
             errStr.contains('unplayable') ||
             errStr.contains('age-restricted') ||
             errStr.contains('restricted') ||
             errStr.contains('forbidden');
    }
    
    final isBrowserPlatform = lowerUrl.contains('instagram.com') ||
        lowerUrl.contains('threads.net') ||
        lowerUrl.contains('threads.com') ||
        lowerUrl.contains('x.com') ||
        lowerUrl.contains('twitter.com') ||
        lowerUrl.contains('facebook.com') ||
        lowerUrl.contains('fb.watch');

    if (isBrowserPlatform) return true;

    // Check if error explicitly demands login or captcha for any platform
    return _isLoginRequiredError(error.toString());
  }

  String _browserPlatformFor(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('instagram.com')) return 'Instagram';
    if (lower.contains('threads.net') || lower.contains('threads.com')) return 'Threads';
    if (lower.contains('x.com') || lower.contains('twitter.com')) return 'X';
    if (lower.contains('youtube.com') || lower.contains('youtu.be')) return 'YouTube';
    if (lower.contains('facebook.com') || lower.contains('fb.watch')) return 'Facebook';
    return 'Social';
  }

  String _cleanError(Object error) {
    final raw = error.toString();
    final cleaned = raw
        .replaceFirst('Exception: ', '')
        .replaceFirst('WebSocketChannelException: ', '')
        .trim();

    final lower = cleaned.toLowerCase();
    if (lower.contains('blocked_adult_content')) {
      return 'Blocked: Adult Content is not allowed.';
    }

    // 1. YouTube specific bot/sign-in errors
    if (lower.contains('sign in') || lower.contains('bot') || lower.contains('captcha') || lower.contains('confirm you are not')) {
      return 'YouTube is blocking this download. Please try again later or try another video.';
    }

    // 2. Facebook/Instagram/TikTok parse/extraction errors
    if (lower.contains('cannot parse data') || lower.contains('extractor') || lower.contains('unable to extract')) {
      return 'Failed to extract media. The post might be private, restricted, or requires browser login.';
    }

    // 3. Private/Login gated content
    if (lower.contains('login') || lower.contains('private') || lower.contains('cookies')) {
      return 'This post requires authentication. Please log in first using the in-app browser.';
    }

    // 4. Unsupported URLs
    if (lower.contains('unsupported url') || lower.contains('unsupported')) {
      return 'Unsupported link. Please paste a valid YouTube, Instagram, Facebook, TikTok, or X/Twitter URL.';
    }

    // 5. Network/Timeout errors
    if (lower.contains('timeout') || lower.contains('connection') || lower.contains('http') || lower.contains('socket')) {
      return 'Connection error. Please check your internet connection and try again.';
    }

    if (cleaned.isEmpty || cleaned == 'null') {
      return 'Download failed. Please try again.';
    }
    return cleaned;
  }

  Future<bool> _isAdultUrl(String url) async {
    try {
      final uri = Uri.parse(url.trim());
      final host = uri.host;
      if (host.isEmpty) return false;

      // 1. Quick local keyword check for instant block (covering porn, hentai, and AI content)
      final lowerHost = host.toLowerCase();
      final localKeywords = [
        'porn', 'xxx', 'sex', 'nude', 'adult', 'camgirl', 'livecam', 
        'hentai', 'xvideo', 'pornhub', 'xnxx', 'xhamster', 'redtube',
        'youporn', 'chaturbate', 'rule34', 'onlyfans', 'stripchat',
        'bongacams', 'camsoda', 'adultfriendfinder', 'cam4', 'imlive',
        'livejasmin', 'doujin', 'nhentai', 'gelbooru', 'danbooru',
        'e621', 'sankakucomplex', 'yande.re', 'rule34.xxx', 'e-hentai',
        'luscious', 'spankbang', 'eporner', 'hqporn', 'motherless',
        'heavyr', 'tube8', 'pornai', 'aiporn', 'nudify', 'undressai',
        'pornpen', 'soulgen', 'candyai', 'dreamgf', 'nsfwai', 'spicychat',
        'janitorai'
      ];
      for (final kw in localKeywords) {
        if (lowerHost.contains(kw)) return true;
      }

      // 2. Query both Cloudflare Families and AdGuard Family DNS in parallel (DoH)
      final results = await Future.wait([
        _queryCloudflareFamilies(host),
        _queryAdGuardFamily(host),
      ]).timeout(const Duration(seconds: 4), onTimeout: () => [false, false]);

      return results[0] || results[1];
    } catch (_) {
      // Fallback: safe to proceed or block on error? Typically false, as we don't want false blocks on random connectivity issues.
    }
    return false;
  }

  Future<bool> _queryCloudflareFamilies(String host) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      final request = await client.getUrl(Uri.parse(
        'https://family.cloudflare-dns.com/dns-query?name=${Uri.encodeComponent(host)}&type=A'
      ));
      request.headers.set('Accept', 'application/dns-json');
      final response = await request.close();
      if (response.statusCode == 200) {
        final bodyText = await response.transform(utf8.decoder).join();
        final data = jsonDecode(bodyText);
        if (data is Map) {
          final answers = data['Answer'];
          if (answers is List) {
            for (final answer in answers) {
              if (answer is Map && (answer['data'] == '0.0.0.0' || answer['data'] == '::')) {
                return true; // Blocked by Cloudflare Families filter
              }
            }
          }
          final comment = data['Comment'];
          if (comment is List) {
            for (final c in comment) {
              if (c.toString().toLowerCase().contains('filtered')) {
                return true; // Filtered/Blocked
              }
            }
          }
        }
      }
    } catch (_) {}
    return false;
  }

  Future<bool> _queryAdGuardFamily(String host) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      final request = await client.getUrl(Uri.parse(
        'https://dns-family.adguard.com/dns-query?name=${Uri.encodeComponent(host)}&type=A'
      ));
      request.headers.set('Accept', 'application/dns-json');
      final response = await request.close();
      if (response.statusCode == 200) {
        final bodyText = await response.transform(utf8.decoder).join();
        final data = jsonDecode(bodyText);
        if (data is Map) {
          final answers = data['Answer'];
          if (answers is List) {
            for (final answer in answers) {
              if (answer is Map) {
                final ip = answer['data'].toString();
                // AdGuard Family DNS blocks adult sites by returning 0.0.0.0, 127.0.0.1, or a block page IP (starts with 94.140)
                if (ip == '0.0.0.0' || ip == '127.0.0.1' || ip.startsWith('94.140.')) {
                  return true;
                }
              }
            }
          }
        }
      }
    } catch (_) {}
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboardOnResume();
    }
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    _sfxPlayer.dispose();
    WidgetsBinding.instance.removeObserver(this);
    premium.removeListener(_premiumChanged);
    _playerStateSubscription.cancel();
    _playerPositionSubscription.cancel();
    for (final sub in _downloadSubscriptions.values) {
      sub.cancel();
    }
    _downloadSubscriptions.clear();
    audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _checkClipboardOnResume() async {
    if (!enableClipboardDetection || busy) return;
    try {
      final url = await _clipboard.readText();
      if (url != null && _isPublicMediaCandidate(url)) {
        if (url != _lastDetectedUrl) {
          detectedClipboardUrl = url;
          unawaited(
            _notifications.showClipboardDetected(
              id: url.hashCode,
              url: url,
            ),
          );
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
        premiumNoWatermark: true,
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
        bool isVideo = false;
        if (batchItem != null) {
          isVideo = batchItem.isVideo;
        } else {
          if (_looksLikeVideoUrl(url)) {
            isVideo = true;
          } else if (_looksLikeImageUrl(url)) {
            isVideo = false;
          } else {
            isVideo = type == DownloadType.video;
          }
        }

        // Additional safeguard to enforce video/image types by url extension
        if (_looksLikeVideoUrl(url)) {
          isVideo = true;
        } else if (_looksLikeImageUrl(url)) {
          isVideo = false;
        }

        final itemType = forceHybrid
            ? (isVideo ? DownloadType.video : DownloadType.image)
            : type;
        debugPrint('DEBUG BATCH: url=$url title=${batchItem?.title} isVideo=$isVideo forceHybrid=$forceHybrid itemType=$itemType');
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
        // YouTube playlist/batch items: ALWAYS download on-device
        if (YouTubeExplodeService.isYouTubeUrl(url)) {
          await _startYouTubeExplodeBatchDownload(
            url: url,
            title: title,
            thumbnail: batchItem?.thumbnail,
            type: itemType,
          );
          started++;
          continue;
        }

        String mediaUrl;
        String? thumbnail;
        String platform;

        if (_looksLikeImageUrl(url) || itemType == DownloadType.image || (itemType == DownloadType.video && isVideo)) {
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
          premiumNoWatermark: true,
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
    Duration? totalDuration,
  }) async {
    if (busy) return;
    final filePath = item.filePath;
    if (filePath == null) {
      throw TrimValidationException('File is not available locally.');
    }

    TrimService.validateRange(
      startSec: startTime,
      endSec: endTime,
      totalDuration: totalDuration ?? Duration(seconds: endTime.ceil()),
    );

    busy = true;
    status = 'Trimming file...';
    notifyListeners();

    String? trimmedTempPath;
    try {
      trimmedTempPath = await _trimService.trimLocalFile(
        inputPath: filePath,
        startSec: startTime,
        endSec: endTime,
        type: item.type,
      );

      final finalPath = await _trimService.replaceOriginal(
        originalPath: filePath,
        trimmedPath: trimmedTempPath,
      );

      final next = item.copyWith(
        filePath: finalPath,
        quality: item.quality != null ? '${item.quality} (trimmed)' : 'trimmed',
      );
      await _saveItem(next);

      if (playerItem?.id == item.id) {
        playerItem = next;
      }
      if (playingItem?.id == item.id) {
        playingItem = next;
        if (item.isAudio) {
          await playItem(next, advanceQueue: true);
        }
      }
      status = 'Trimming complete';
    } catch (error) {
      if (trimmedTempPath != null) {
        final temp = File(trimmedTempPath);
        if (await temp.exists()) {
          await temp.delete();
        }
      }
      status = error is TrimValidationException
          ? error.message
          : _cleanError(error);
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
      await _store.writeYoutubeCookies(content);
      _ytExplode.updateCookies(content);
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
      await _store.writeYoutubeCookies(null);
      _ytExplode.updateCookies(null);
      status = 'Cookies cleared';
      notifyListeners();
    } catch (e) {
      status = 'Failed to clear cookies: $e';
      notifyListeners();
      rethrow;
    }
  }

  DateTime? _lastBackPressTime;

  bool handleDoubleBackToExit() {
    final now = DateTime.now();
    if (_lastBackPressTime == null || now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
      _lastBackPressTime = now;
      return false;
    }
    return true;
  }

  void _initSharingListener() {
    // Skip sharing listener initialization in unit test environment to avoid MissingPluginException
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }

    // For sharing while app is running/backgrounded
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((value) {
      if (value.isNotEmpty) {
        final path = value.first.path;
        _handleSharedText(path);
      }
    }, onError: (err) {
      debugPrint("Sharing intent stream error: $err");
    });

    // For sharing that triggers a cold start
    ReceiveSharingIntent.instance.getInitialMedia().then((value) {
      if (value.isNotEmpty) {
        final path = value.first.path;
        _handleSharedText(path);
      }
    });
  }

  Future<void> _handleSharedText(String text) async {
    final regExp = RegExp(r'(https?://[^\s]+)');
    final match = regExp.firstMatch(text);
    final url = match?.group(0);
    if (url != null) {
      unawaited(autoExtractAndDownload(url));
    }
  }

  Future<void> autoExtractAndDownload(String url) async {
    if (busy) return;
    busy = true;
    lastDownloadedItem = null;
    flow = DuckFlow.extracting;
    status = 'Auto-downloading shared link...';
    notifyListeners();

    try {
      final cleanUrl = url.trim();
      final isAdult = await _isAdultUrl(cleanUrl);
      if (isAdult) {
        isAdultContentBlocked = true;
        notifyListeners();
        throw Exception('BLOCKED_ADULT_CONTENT');
      }


      // 2. Instagram
      if (cleanUrl.contains('instagram.com')) {
        final playlist = await _api.extractPlaylist(cleanUrl);
        if (playlist.items.isNotEmpty) {
          busy = false;
          for (final item in playlist.items) {
            final itemMeta = await _api.extract(item.url);
            metadata = itemMeta;
            selectedType = _isImageMetadata(itemMeta) ? DownloadType.image : DownloadType.video;
            quality = _firstQuality(itemMeta, selectedType);
            await startDownload();
            busy = false;
          }
          showAdOnOpen = true;
          notifyListeners();
          return;
        }
      }

      // 3. Other Platforms (TikTok, Facebook, Twitter, etc.) — all via server
      final media = await _api.extract(cleanUrl);
      metadata = media;
      final isImg = _isImageMetadata(media) || _looksLikeImageUrl(cleanUrl);
      selectedType = isImg ? DownloadType.image : DownloadType.video;
      quality = _firstQuality(media, selectedType);
      busy = false;
      await startDownload();
      showAdOnOpen = true;
      notifyListeners();
    } catch (error) {
      flow = DuckFlow.error;
      status = _cleanError(error);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> _promptPlaylistChoice(String url) async {
    pendingPlaylistUrl = url;
    showPlaylistChoiceDialog = true;
    _playlistChoiceCompleter = Completer<bool>();
    notifyListeners();
    final choice = await _playlistChoiceCompleter!.future;
    showPlaylistChoiceDialog = false;
    pendingPlaylistUrl = null;
    notifyListeners();
    return choice;
  }

  void resolvePlaylistChoice(bool downloadPlaylist) {
    if (_playlistChoiceCompleter != null && !_playlistChoiceCompleter!.isCompleted) {
      _playlistChoiceCompleter!.complete(downloadPlaylist);
    }
  }

  String _stripPlaylistParam(String url) {
    try {
      final uri = Uri.parse(url);
      final queryParams = Map<String, String>.from(uri.queryParameters);
      queryParams.remove('list');
      queryParams.remove('index');
      return uri.replace(queryParameters: queryParams).toString();
    } catch (_) {
      return url;
    }
  }
}
