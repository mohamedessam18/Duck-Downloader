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
import '../core/haptics.dart';
import '../services/camera_service.dart';
import '../core/notifications/notification_service.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/permissions/permission_service.dart';
import '../models/download_models.dart';
import '../services/api_client.dart';
import '../services/clipboard_service.dart';
import '../services/crash_reporting_service.dart';
import '../services/download_store.dart';
import '../services/file_service.dart';
import '../models/meta_post.dart';
import '../services/meta_post_service.dart';
import '../services/platform_sessions.dart';
import '../services/premium_entitlement.dart';
import '../services/premium_manager.dart';
import '../services/media_save_service.dart';
import '../services/trim_service.dart';
import '../services/share_bridge.dart';
import '../services/youtube_explode_service.dart';
import 'duck_status.dart';
import '../services/vault_encryption_service.dart';
import '../services/conversion_service.dart';
import '../services/cobalt_service.dart';
import '../services/reddit_service.dart';
import '../services/device_media_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// What the adult-content check was able to establish.
///
/// A plain bool could not tell "this link is fine" apart from "nothing
/// answered", and the two were treated identically — so a Reddit post whose
/// NSFW flag could not be read was downloaded as though it had come back
/// clean.
enum _AdultVerdict {
  allowed,
  blocked,

  /// The one authoritative source for this link did not answer.
  unverified,
}

/// One download that has a row in the library but has not reached the backend.
class _PendingDownload {
  _PendingDownload({required this.placeholderId, required this.begin});

  final String placeholderId;

  /// Returns the backend's download id. Not called until a slot frees up.
  final Future<String> Function() begin;
}

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
    MetaPostService? meta,
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
       _ytExplode = ytExplode ?? YouTubeExplodeService(),
       _meta = meta ?? MetaPostService() {
    unawaited(_loadYouTubeSession());
    _downloads = _store.readDownloads();
    for (final item in _downloads.where((item) => item.isPrivate)) {
      _privateMetadata[item.id] = item;
    }
    _videoResumePositions = _store.readVideoResumePositions();
    // Every other preference survives a restart — quality, type, where a video
    // was paused. These two were the exception, so turning shuffle on and
    // reopening the app silently turned it back off.
    shuffleEnabled = _store.readShuffleEnabled();
    _loopMode = _readStoredLoopMode(_store.readPlaybackLoopMode());
    autoSaveVideos = _store.readAutoSaveVideos();
    enableClipboardDetection = _store.readEnableClipboardDetection();
    crashReportingEnabled = _store.readCrashReportingEnabled();
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
        unawaited(_initializePlatformServices());
        // Point the native share sheet at the same backend this build
        // resolved, then collect anything it finished while Duck was closed.
        unawaited(_shareBridge.syncConfig(apiBaseUrl: _api.apiBaseUrl));
        unawaited(_drainShareInbox());
        unawaited(_recoverInterruptedDownloads());
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

  /// Takes a track out of the queue, including the one playing.
  ///
  /// Removing the current track used to be refused outright — the row simply
  /// did not respond, with nothing to say why. Skipping to the next one is
  /// what the user asked for, so do that and then remove it.
  void removeFromQueue(int index) {
    if (index < 0 || index >= _audioQueue.length) return;
    if (_audioQueue.length <= 1) return;

    if (index == _audioQueueIndex) {
      final next = _audioQueue[(index + 1) % _audioQueue.length];
      _audioQueue.removeAt(index);
      // The list shrank under the index; wrapping past the end means starting
      // over at the top.
      _audioQueueIndex = index >= _audioQueue.length ? 0 : index;
      unawaited(playItem(next, advanceQueue: true));
      notifyListeners();
      return;
    }

    _audioQueue.removeAt(index);
    if (index < _audioQueueIndex) _audioQueueIndex--;
    notifyListeners();
  }

  void playFromQueue(int index) {
    if (index < 0 || index >= _audioQueue.length) return;
    _audioQueueIndex = index;
    playItem(_audioQueue[index], advanceQueue: true);
  }

  bool get hasNextVideo =>
      _videoQueue.length > 1 && _videoQueueIndex < _videoQueue.length - 1;
  bool get hasPreviousVideo => _videoQueue.length > 1 && _videoQueueIndex > 0;
  DownloadItem? get nextVideoItem =>
      hasNextVideo ? _videoQueue[_videoQueueIndex + 1] : null;

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
  final RedditService _reddit = RedditService();
  final YouTubeExplodeService _ytExplode;

  List<DownloadItem> _downloads = [];
  final Map<String, DownloadItem> _privateMetadata = {};
  bool _privateMetadataIndexHealthy = true;
  List<Playlist> _playlists = [];
  String? _vaultPin;
  String? _decoyVaultPin;
  bool _biometricEnabled = false;
  bool get isVaultSetup =>
      VaultEncryptionService.isConfigured || _vaultPin != null;
  bool get isDecoyVaultSetup =>
      VaultEncryptionService.isDecoyConfigured || _decoyVaultPin != null;
  bool get biometricEnabled => _biometricEnabled;
  bool isVaultLocked = true;
  bool isDecoySession = false;
  int _failedPinAttempts = 0;
  DownloadItem? lastDownloadedItem;
  bool downloadDirectToVault = false;
  bool isAdultContentBlocked = false;

  DuckFlow flow = DuckFlow.idle;
  DuckTab tab = DuckTab.home;
  DuckStatus _status = const DuckStatus.key('statusTapDuck');

  /// The status line as a translation key, for whatever is displaying it.
  DuckStatus get statusMessage => _status;

  /// The same line in English.
  ///
  /// Kept as a plain `String` because a lot of code — and every test — reads
  /// it that way, and because the one remaining piece of UI that has to
  /// recognise a specific message needs something stable to match on.
  String get status => _status.english;

  set status(String value) => _status = DuckStatus.literal(value);

  /// Sets the status from a translation key rather than a finished sentence.
  void setStatus(String key, [Map<String, String> args = const {}]) {
    _status = DuckStatus.key(key, args: args);
  }
  MediaMetadata? metadata;
  List<PlaylistItem>? batchItems;
  String? batchTitle;
  String? batchPlatform;
  DownloadType selectedType = DownloadType.video;
  BackendCookiesInfo? backendCookies;

  /// The sign-in the app is asking for, or null.
  ///
  /// Private with an explicit setter because the previous public field was
  /// assigned directly from the "Open In-App Browser" button, which meant no
  /// `notifyListeners` ran and the screen listening for it never rebuilt.
  /// Tapping the button did nothing at all until some unrelated change
  /// happened to notify, and then a browser appeared out of nowhere.
  LoginRequest? _loginRequest;
  LoginRequest? get loginRequest => _loginRequest;

  /// Signed-in sessions, per platform, encrypted on this device.
  final PlatformSessionStore _sessions = const PlatformSessionStore();

  final MetaPostService _meta;

  /// Which of the two Meta platforms [_metaPost] came from.
  SocialPlatform? _metaPlatform;

  String get _metaPlatformLabel =>
      _metaPlatform == null ? 'Instagram' : profileFor(_metaPlatform!).label;

  /// The Instagram or Threads post the current options or batch came from.
  ///
  /// Held because its items carry direct CDN URLs, which download on this
  /// device instead of being posted to the backend for it to fetch.
  MetaPost? _metaPost;

  String? lastAttemptedUrl;
  String quality = 'Best';
  bool busy = false;

  /// True while re-running an extraction that a sign-in was supposed to fix.
  ///
  /// Guards the obvious loop: fail, sign in, fail again, ask to sign in again.
  bool _justSignedIn = false;
  bool autoSaveVideos = true;
  bool enableClipboardDetection = true;
  bool crashReportingEnabled = true;
  String? detectedClipboardUrl;
  String? _lastDetectedUrl;

  Completer<bool>? _playlistChoiceCompleter;
  bool showPlaylistChoiceDialog = false;
  String? pendingPlaylistUrl;
  bool externalSaveBusy = false;
  String? activeId;
  String? _activeDecryptedAudioPath;
  DownloadItem? playerItem;
  String? _playerTempPath;
  List<DownloadItem>? playerGalleryItems;
  List<DownloadItem>? _audioQueueSource;
  final Set<String> controlPendingIds = {};
  final Map<String, StreamSubscription> _downloadSubscriptions = {};

  void _cancelDownloadSubscription(String id) {
    _downloadSubscriptions[id]?.cancel();
    _downloadSubscriptions.remove(id);
  }

  /// A download is over — for any reason — so its slot goes back to the queue.
  ///
  /// Separate from [_cancelDownloadSubscription] because that is also called
  /// at the top of [_watchDownload] to clear a previous socket for the same
  /// id. Folding the two together meant every download handed its slot back
  /// the instant it started watching itself, so the concurrency cap held
  /// nothing back at all.
  void _finishDownload(String id) {
    _cancelDownloadSubscription(id);
    _releaseDownloadSlot(id);
  }

  // ── The download queue ────────────────────────────────────────────────────

  /// How many downloads run at once without Premium.
  ///
  /// There was no queue at all before this. `DownloadStatus.queued` existed as
  /// a label but nothing enforced it: every call site created an item and
  /// immediately hit `/api/download`, so sharing a 40-video playlist opened 40
  /// simultaneous jobs — 40 backend workers, 40 sockets, and a phone dividing
  /// its bandwidth 40 ways so that nothing finished for a very long time.
  ///
  /// Three is where mainstream downloaders land: fast enough that a playlist
  /// moves, few enough that each stream gets real bandwidth.
  static const freeConcurrentDownloads = 3;

  /// The same, with Premium.
  ///
  /// Five rather than three is the whole of "Faster Downloads" on the paywall.
  /// Deliberately a modest step: the phone and the backend are shared with
  /// everyone else, and a number high enough to feel dramatic in a demo is
  /// high enough to make every individual download slower on real signal.
  static const premiumConcurrentDownloads = 5;

  /// The cap in force right now.
  ///
  /// Read on every pump rather than cached, so buying Premium with a queue
  /// already backed up starts the extra downloads immediately instead of at
  /// the next launch.
  int get maxConcurrentDownloads =>
      premium.hasFeature(PremiumFeature.fasterProcessing)
      ? premiumConcurrentDownloads
      : freeConcurrentDownloads;

  /// Downloads waiting for a slot, oldest first.
  final List<_PendingDownload> _pendingDownloads = [];

  /// Ids currently holding a slot. A set, not a counter, so releasing the same
  /// download twice cannot hand out a slot that was never taken.
  final Set<String> _runningDownloads = {};

  int _localIdCounter = 0;

  /// An id for a row that exists before the backend has been told anything.
  ///
  /// Prefixed so it is obvious in storage that this is not a backend id, and
  /// counted as well as timestamped because a batch loop creates several
  /// within the same microsecond.
  String _newLocalDownloadId() =>
      'local_${DateTime.now().microsecondsSinceEpoch}_${_localIdCounter++}';

  final ShareBridge _shareBridge = ShareBridge();

  // ── Surviving the background ──────────────────────────────────────────────

  DateTime? _lastKeepAlivePush;
  bool _keepAliveHeld = false;

  /// How often the notification's numbers are refreshed while downloading.
  ///
  /// Progress arrives per network chunk; a platform call per chunk would cost
  /// far more than the one-second staleness it buys.
  static const _keepAliveRefresh = Duration(seconds: 1);

  /// Asks the native service to keep this process alive while work is running.
  ///
  /// Without this an in-app download dies the moment the user switches to
  /// WhatsApp: Android freezes the Flutter isolate and takes every open socket
  /// with it. The service holds the process up; Dart still does the
  /// downloading.
  void _syncKeepAlive() {
    final active = activeDownloads;
    final busyNow = active.isNotEmpty || _pendingDownloads.isNotEmpty;

    if (!busyNow) {
      if (!_keepAliveHeld) return;
      _keepAliveHeld = false;
      _lastKeepAlivePush = null;
      unawaited(_shareBridge.releaseKeepAlive());
      return;
    }

    final now = DateTime.now();
    final due = _lastKeepAlivePush == null ||
        now.difference(_lastKeepAlivePush!) >= _keepAliveRefresh;
    // A transition into "busy" is never throttled: the service has to be up
    // before the user has a chance to leave.
    if (_keepAliveHeld && !due) return;
    _lastKeepAlivePush = now;
    _keepAliveHeld = true;

    final total = active.length + _pendingDownloads.length;
    final head = active.firstOrNull;
    final percent = active.isEmpty
        ? 0
        : (active.map((item) => item.progress).reduce((a, b) => a + b) /
                  active.length)
              .round()
              .clamp(0, 100);
    unawaited(
      _shareBridge.holdKeepAlive(
        title: head?.title ?? 'Duck Downloader',
        percent: percent,
        running: active.length,
        total: total,
      ),
    );
  }

  /// How long an unfinished download is still worth reconnecting to.
  ///
  /// The backend keeps a job and its file for a while, not forever. Past this
  /// the socket would open onto nothing and report a failure that reads like a
  /// fresh error for something that went wrong yesterday.
  static const _resumeWindow = Duration(hours: 2);

  /// Deals with downloads the app was killed in the middle of.
  ///
  /// Nothing used to: an item left `downloading` when the process died stayed
  /// `downloading` forever, with no socket behind it and no way for the user
  /// to retry it — a progress bar frozen at 40% that outlived reboots.
  ///
  /// Recent server-side jobs get their socket back, because the backend has
  /// most likely carried on without us. Everything else is marked failed so it
  /// can be retried instead of sitting there lying.
  Future<void> _recoverInterruptedDownloads() async {
    final now = DateTime.now();
    final interrupted = _downloads
        .where(
          (item) =>
              item.status == DownloadStatus.queued ||
              item.status == DownloadStatus.downloading ||
              item.status == DownloadStatus.processing,
        )
        .toList();

    for (final item in interrupted) {
      // A local id means the queue never got as far as telling the backend
      // about it, so there is nothing on the other end to reconnect to.
      final reachedBackend = !item.id.startsWith('local_');
      final recent = now.difference(item.createdAt) < _resumeWindow;

      if (reachedBackend && recent) {
        _runningDownloads.add(item.id);
        _watchDownload(item.id, item);
        continue;
      }
      try {
        await _saveItem(item.copyWith(status: DownloadStatus.failed));
      } catch (error, stackTrace) {
        // A private item whose vault is still locked. It will be picked up
        // the next time the vault opens rather than blocking startup.
        reportError(error, stackTrace, reason: 'download-recovery');
      }
    }
    _pumpDownloadQueue();
  }

  /// Folds in downloads the native share service finished while Duck was shut.
  ///
  /// Runs at launch and on every resume: the user shares a link from Facebook,
  /// never opens Duck, and the file has to be waiting in the library the next
  /// time they do.
  Future<void> _drainShareInbox() async {
    try {
      final finished = await _shareBridge.drain();
      if (finished.isEmpty) return;
      for (final item in finished) {
        // A share can only ever be a normal download; nothing outside the app
        // can write to the vault, which needs a key that lives behind the PIN.
        await _store.upsert(item);
      }
      _downloads = _store.readDownloads();
      _mergePrivateMetadata();
      notifyListeners();
    } catch (error, stackTrace) {
      reportError(error, stackTrace, reason: 'share-inbox-drain');
    }
  }

  int get queuedDownloadCount => _pendingDownloads.length;
  int get runningDownloadCount => _runningDownloads.length;

  /// Puts a download in the library immediately and starts it when there is
  /// room.
  ///
  /// [placeholder] is a real row the user can see and cancel while it waits.
  /// [begin] is the call that actually reaches the backend; it is not made
  /// until this download's turn, which is the entire point — a queued item
  /// must not occupy a backend worker.
  ///
  /// The backend hands back its own id, so when the job finally starts the
  /// placeholder is replaced by a row keyed on that id.
  Future<void> _enqueueDownload({
    required DownloadItem placeholder,
    required Future<String> Function() begin,
  }) async {
    await _saveItem(placeholder);
    _pendingDownloads.add(
      _PendingDownload(placeholderId: placeholder.id, begin: begin),
    );
    _pumpDownloadQueue();
  }

  bool _pumping = false;
  bool _pumpAgain = false;
  bool _disposed = false;

  void _pumpDownloadQueue() {
    // Nothing may start after the controller is gone: its storage is closed
    // and its listeners are detached, so a job that begins here writes into a
    // box nobody owns any more.
    if (_disposed) return;
    // A download can finish synchronously inside the loop below — a cached
    // file, a fake API in a test — which lands straight back here and starts
    // taking items off a list the outer loop is still walking. That reordered
    // the queue and dropped entries. Nested calls now just ask for another
    // pass once the current one is done.
    if (_pumping) {
      _pumpAgain = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _pumpAgain = false;
        _drainPendingDownloads();
      } while (_pumpAgain);
    } finally {
      _pumping = false;
    }
    _syncKeepAlive();
    notifyListeners();
  }

  void _drainPendingDownloads() {
    while (_runningDownloads.length < maxConcurrentDownloads &&
        _pendingDownloads.isNotEmpty) {
      final pending = _pendingDownloads.removeAt(0);
      final placeholder = _downloads
          .where((item) => item.id == pending.placeholderId)
          .firstOrNull;
      // Cancelled or deleted while it sat in the queue. Nothing to start, and
      // no slot to take.
      if (placeholder == null ||
          placeholder.status != DownloadStatus.queued) {
        continue;
      }
      _runningDownloads.add(pending.placeholderId);
      unawaited(_startPending(pending, placeholder));
    }
  }

  Future<void> _startPending(
    _PendingDownload pending,
    DownloadItem placeholder,
  ) async {
    // Which id is actually holding the slot right now. It changes halfway
    // through, and releasing the one that is no longer held leaks a slot —
    // three of those and the queue stops starting anything for the rest of
    // the session.
    var heldId = pending.placeholderId;
    var failedItem = placeholder;
    try {
      final backendId = await pending.begin();
      if (_disposed) return;

      // The placeholder's id was ours; the real one is the backend's, and the
      // rest of the controller keys everything on it. Swap the row rather than
      // carry two ids around.
      final started = DownloadItem.fromJson({
        ...placeholder.toJson(),
        'id': backendId,
        'status': DownloadStatus.downloading.name,
      });
      _runningDownloads.remove(heldId);
      _runningDownloads.add(backendId);
      heldId = backendId;
      failedItem = started;
      if (backendId != placeholder.id) {
        _privateMetadata.remove(placeholder.id);
        await _store.delete(placeholder.id);
        // The in-memory list still holds the placeholder, and _saveItem
        // rewrites the whole list from it — which would put the row straight
        // back, leaving every download in the library twice.
        _downloads = _store.readDownloads();
      }
      await _saveItem(started);
      activeId = backendId;
      // From here the slot belongs to the watcher, which releases it on the
      // first terminal update.
      _watchDownload(backendId, started);
    } catch (error) {
      flow = DuckFlow.error;
      _status = _errorStatus(error);
      try {
        await _saveItem(failedItem.copyWith(status: DownloadStatus.failed));
      } catch (saveError, stackTrace) {
        reportError(saveError, stackTrace, reason: 'queue-start-failure');
      }
      _releaseDownloadSlot(heldId);
    }
    notifyListeners();
  }

  void _releaseDownloadSlot(String id) {
    if (_runningDownloads.remove(id)) {
      _pumpDownloadQueue();
    }
  }

  /// Drops everything still waiting for a slot.
  ///
  /// The running downloads are left alone: they are already costing bandwidth
  /// and are the ones nearest to being useful.
  Future<void> clearDownloadQueue() async {
    final waiting = List.of(_pendingDownloads);
    _pendingDownloads.clear();
    for (final pending in waiting) {
      _privateMetadata.remove(pending.placeholderId);
      await _store.delete(pending.placeholderId);
    }
    _downloads = _store.readDownloads();
    _mergePrivateMetadata();
    notifyListeners();
  }

  bool removeMusic = false;

  void toggleRemoveMusic(bool value) {
    removeMusic = value;
    notifyListeners();
  }

  /// Hands the saved YouTube session to the on-device extractor at startup.
  ///
  /// Also moves the one left by older builds. That copy lived in the plain
  /// Hive box beside the download list — a Google session in clear text, in
  /// the same file as everything else — so it is read once, written to the
  /// encrypted per-platform store, and deleted.
  Future<void> _loadYouTubeSession() async {
    final legacy = _store.readYoutubeCookies();
    if (legacy != null && legacy.trim().isNotEmpty) {
      if (!await _sessions.hasSession(SocialPlatform.youtube)) {
        await _sessions.write(SocialPlatform.youtube, legacy);
      }
      await _store.writeYoutubeCookies(null);
    }
    final cookies = await _sessions.read(SocialPlatform.youtube);
    if (cookies != null) _ytExplode.updateCookies(cookies);
    await _syncSessionsToNative();
  }

  /// Drops a pending sign-in request. Called once the screen has taken it.
  void clearLoginRequest() {
    if (_loginRequest == null) return;
    _loginRequest = null;
    notifyListeners();
  }

  /// Asks the user to sign in, so the link they pasted can be retried.
  ///
  /// Returns false when nothing here can sign into this link's site, so the
  /// caller reports the real error instead of opening a sign-in screen that
  /// could not possibly help.
  bool _requestLogin(String url) {
    final profile = profileForUrl(url);
    if (profile == null) return false;
    _loginRequest = LoginRequest(platform: profile.platform, retryUrl: url);
    flow = DuckFlow.ready;
    setStatus('statusSignInRequired');
    return true;
  }

  /// Re-opens the sign-in the app last asked for.
  ///
  /// This is what the button on the home screen calls. It goes through the
  /// setter so the change is announced — assigning the field from the button
  /// was the reason pressing it appeared to do nothing.
  void openLoginForLastAttempt() {
    final url = _loginRequest?.retryUrl ?? lastAttemptedUrl;
    if (url == null) return;
    final profile = profileForUrl(url);
    if (profile == null) return;
    _loginRequest = LoginRequest(platform: profile.platform, retryUrl: url);
    notifyListeners();
  }

  /// Called once the user has signed in: pick the link back up.
  ///
  /// The sign-in exists to finish a download that was already asked for, so
  /// finishing it is this method's whole job. The old screen ended by handing
  /// back a list of images it had scraped out of whatever page happened to be
  /// open, which is why navigating anywhere during the login changed what got
  /// downloaded.
  Future<void> completeLogin(LoginRequest request) async {
    _loginRequest = null;
    await _syncSessionsToNative();
    if (request.platform == SocialPlatform.youtube) {
      // youtube_explode extracts on the device, so it needs the session too —
      // handing it only to the backend would leave the on-device path signed
      // out.
      _ytExplode.updateCookies(await _sessions.read(SocialPlatform.youtube));
    }
    setStatus('statusSignedInRetrying');
    notifyListeners();
    await extractUrl(request.retryUrl, afterSignIn: true);
  }

  /// True when this platform already has a saved session.
  Future<bool> hasSessionFor(SocialPlatform platform) =>
      _sessions.hasSession(platform);

  /// Which platforms are currently signed in.
  Future<Set<SocialPlatform>> signedInPlatforms() => _sessions.signedIn();

  /// Mirrors the saved sessions to the native side.
  ///
  /// A link shared from another app is handled by ShareActivity and
  /// DownloadService, which call the backend directly and never start a
  /// Flutter isolate. Without this, signing into Instagram inside Duck did
  /// nothing for a private post shared *into* Duck: the two entry points
  /// disagreed about who the user was.
  ///
  /// The hosts travel with each jar so the native side never needs its own
  /// copy of the platform table — a second copy is what let the old code
  /// forget about Threads and Udemy.
  Future<void> _syncSessionsToNative() async {
    if (!Platform.isAndroid) return;
    try {
      final entries = <Map<String, Object>>[];
      for (final profile in allPlatformProfiles) {
        final cookies = await _sessions.read(profile.platform);
        if (cookies == null) continue;
        entries.add({'hosts': profile.hosts, 'cookies': cookies});
      }
      await _channel.invokeMethod<bool>('syncSessions', {
        'sessions': entries.isEmpty ? null : jsonEncode(entries),
      });
    } catch (_) {
      // Older installs and every non-Android platform land here. Downloads
      // started from the share sheet simply run signed out.
    }
  }

  bool get isPremiumActive => premium.isPremium;
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
    // Buying Premium raises the concurrency cap, and someone who paid while
    // watching a playlist crawl should see the extra downloads start now, not
    // after a restart.
    _pumpDownloadQueue();
    notifyListeners();
  }

  List<DownloadItem> get downloads => List.unmodifiable(_downloads);
  List<Playlist> get playlists => List.unmodifiable(_playlists);
  List<DownloadItem> get videos => _completed(DownloadType.video);
  List<DownloadItem> get audios => _completed(DownloadType.audio);
  List<DownloadItem> get images => _completed(DownloadType.image);

  final DeviceMediaService _deviceMediaService = DeviceMediaService();
  List<DeviceMediaFolder> videoFolders = [];
  List<DeviceMediaFolder> imageFolders = [];
  List<DeviceMediaFolder> audioFolders = [];

  /// True once a scan has run and the user has refused media access.
  ///
  /// Distinguishing this from "scanned and found nothing" is what lets the
  /// folders tab offer a way forward instead of an empty screen the user
  /// cannot act on.
  bool deviceMediaAccessDenied = false;

  /// True while a library read is in flight, so the browser can show progress
  /// instead of an empty state it would otherwise mistake for "no files".
  bool deviceFoldersLoading = false;

  /// When the folder lists were last read, so they can go stale.
  DateTime? _deviceFoldersReadAt;

  /// How long a listing is trusted before the browser re-reads it.
  ///
  /// Short, because the whole point is noticing files and folders that other
  /// apps created while Duck was open — a camera shot, a WhatsApp download.
  /// The read itself is one MediaStore query, so this is cheap.
  static const _deviceFoldersFreshFor = Duration(seconds: 20);

  /// Loads folders when the browser opens, and again once they go stale.
  ///
  /// This used to return early forever after the first successful read, which
  /// meant a folder created after launch never showed up until the app was
  /// restarted. Staleness is time-based instead.
  /// Whether this session has already put the system permission prompt up.
  bool _deviceMediaPermissionAsked = false;

  Future<void> ensureDeviceFolders() async {
    if (deviceFoldersLoading) return;
    final readAt = _deviceFoldersReadAt;
    // Deliberately keyed on the last *attempt*, not the last success. Keying
    // it on success meant a denied permission never marked anything, so the
    // folders tab — which calls this after every frame — re-entered on every
    // rebuild, and each pass raised the permission dialog again. That storm is
    // what made the browser look completely dead rather than merely empty.
    if (readAt != null &&
        DateTime.now().difference(readAt) < _deviceFoldersFreshFor) {
      return;
    }
    // Prompt once per session. The intro can be skipped, so arriving here
    // having never been asked is a normal path — but asking again on every
    // refresh is not.
    final shouldAsk = !_deviceMediaPermissionAsked;
    _deviceMediaPermissionAsked = true;
    await refreshDeviceFolders(requestPermission: shouldAsk);
    await ensureDeviceWriteAccess();
  }

  /// Whether this session has already put the bulk write-consent dialog up.
  bool _deviceWriteAccessAsked = false;

  /// Asks once for permission to modify the user's own media.
  ///
  /// READ_MEDIA_* covers reading and nothing else; every rename, move and
  /// delete of a file Duck did not create needs the user's consent, and
  /// Android will only take that consent through its own dialog. What it does
  /// allow is asking about a whole batch at once, so the browser asks for the
  /// library the first time it opens and every edit after that is silent.
  ///
  /// Deliberately best-effort. If the user says no, or the dialog never
  /// appears, nothing breaks — each edit falls back to asking for itself.
  Future<void> ensureDeviceWriteAccess() async {
    if (_deviceWriteAccessAsked) return;
    // Persisted, because the grant the dialog obtains outlives the process.
    // Re-asking every launch would be nagging for something already held.
    if (_store.readMediaWriteAccessAsked()) {
      _deviceWriteAccessAsked = true;
      return;
    }
    // No read access means no library to ask about, and asking to modify
    // files the user has not agreed to let us see reads as a trick.
    if (deviceMediaAccessDenied) return;

    _deviceWriteAccessAsked = true;
    // Written before the dialog goes up, so a crash or a force-stop while it
    // is on screen cannot turn this into a prompt on every launch.
    await _store.writeMediaWriteAccessAsked(true);

    final paths = await _deviceMediaService.libraryPaths();
    if (paths.isEmpty) return;
    await _deviceMediaService.requestWriteAccess(paths);
  }

  Future<void> refreshDeviceFolders({bool requestPermission = true}) async {
    if (deviceFoldersLoading) return;
    deviceFoldersLoading = true;
    notifyListeners();
    try {
      final granted = requestPermission
          ? await _permissions.requestMediaLibraryAccess()
          : await _permissions.hasMediaLibraryAccess();
      deviceMediaAccessDenied = !granted;
      if (!granted) {
        videoFolders = const [];
        imageFolders = const [];
        audioFolders = const [];
        return;
      }

      // Always re-read. This method only runs when the listing is already
      // stale or the user explicitly asked, so honouring the service's own
      // cache here would just stack a second expiry on top of the first and
      // hand back the very data we came to replace. The service cache still
      // does its job below: it turns the three foldersFor calls into one
      // MediaStore query.
      _deviceMediaService.invalidate();
      videoFolders = await _deviceMediaService.foldersFor(DownloadType.video);
      imageFolders = await _deviceMediaService.foldersFor(DownloadType.image);
      audioFolders = await _deviceMediaService.foldersFor(DownloadType.audio);
      debugPrint(
        'FOLDERS: ${videoFolders.length} video, ${imageFolders.length} image, '
        '${audioFolders.length} audio',
      );
    } catch (error, stackTrace) {
      reportError(error, stackTrace, reason: 'device-media-scan');
    } finally {
      // In the finally, so a denial or a thrown read still counts as an
      // attempt and cannot spin the caller.
      _deviceFoldersReadAt = DateTime.now();
      deviceFoldersLoading = false;
      notifyListeners();
    }
  }

  // ── Back navigation ───────────────────────────────────────────────────────

  /// Layers that get first refusal on the back gesture, innermost last.
  ///
  /// Back used to be a single if-chain in the root screen's PopScope, which
  /// could only reason about state that screen happened to hold. Anything
  /// owning a dismissible layer of its own — the player's option panels, a
  /// folder sheet in selection mode — was invisible to it, so back sailed past
  /// them and tore down the whole screen instead of closing the one thing the
  /// user was looking at. Layers register as they appear and unregister as
  /// they go, and the chain is walked from the innermost outwards.
  final List<bool Function()> _backInterceptors = [];

  /// True while some layer wants a say in the back gesture.
  bool get hasBackInterceptors => _backInterceptors.isNotEmpty;

  void addBackInterceptor(bool Function() handler) {
    _backInterceptors.add(handler);
  }

  void removeBackInterceptor(bool Function() handler) {
    _backInterceptors.remove(handler);
  }

  /// Offers the back gesture to each layer, innermost first.
  ///
  /// Returns true as soon as one consumes it. Iterating over a copy because a
  /// handler is free to unregister itself as it closes.
  bool handleBackIntercept() {
    for (final handler in _backInterceptors.reversed.toList()) {
      if (handler()) return true;
    }
    return false;
  }

  /// Destination candidates for a move.
  Future<List<DeviceMediaFolder>> deviceDestinationFolders() =>
      _deviceMediaService.destinationFolders();

  /// Re-reads a single folder after an edit.
  Future<DeviceMediaFolder?> refreshDeviceFolder({
    required String path,
    required DownloadType type,
  }) => _deviceMediaService.refreshFolder(path, type);

  /// Every device-media edit goes through here.
  ///
  /// Two things used to be left to each call site and were forgotten at half
  /// of them: renaming through a *second* `DeviceMediaService` instance, whose
  /// cache invalidation nobody read, and never refreshing the folder grid — so
  /// a rename the user had just confirmed kept showing the old name until the
  /// 20-second staleness window happened to expire.
  Future<DeviceMediaEditOutcome> _runDeviceEdit(
    Future<DeviceMediaEditOutcome> Function() edit,
  ) async {
    final outcome = await edit();
    if (outcome.result == DeviceMediaEditResult.success) {
      // Permission is already granted — anything else would have failed long
      // before here — so re-read without putting the system prompt back up.
      await refreshDeviceFolders(requestPermission: false);
    }
    return outcome;
  }

  Future<DeviceMediaEditOutcome> renameDeviceMedia({
    required String path,
    required String newName,
  }) => _runDeviceEdit(
    () => _deviceMediaService.rename(path: path, newName: newName),
  );

  Future<DeviceMediaEditOutcome> deleteDeviceMedia(List<String> paths) =>
      _runDeviceEdit(() => _deviceMediaService.delete(paths));

  Future<DeviceMediaEditOutcome> moveDeviceMedia({
    required List<String> paths,
    required String targetFolder,
  }) => _runDeviceEdit(
    () => _deviceMediaService.move(paths: paths, targetFolder: targetFolder),
  );

  Future<DeviceMediaEditOutcome> updateDeviceMediaTags({
    required String path,
    String? title,
    String? artist,
    String? album,
  }) => _runDeviceEdit(
    () => _deviceMediaService.updateTags(
      path: path,
      title: title,
      artist: artist,
      album: album,
    ),
  );

  /// Opens the system settings page so the user can grant access after a
  /// permanent denial, where an in-app prompt would no longer appear.
  Future<void> openDeviceMediaSettings() => openAppSettings();

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
      // Here rather than in the nav bar, so tapping, dragging the pill and
      // programmatic jumps (notification taps, clipboard accept) all tick.
      DuckHaptics.selection();
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

  /// How long the vault stays closed after too many wrong PINs.
  ///
  /// A numeric PIN has a small keyspace, so the work factor of the key
  /// derivation alone cannot stop an attacker who can keep guessing. Making
  /// each additional wrong guess cost real time is what actually does — the
  /// delay doubles from 5 seconds and caps at five minutes.
  Duration get vaultLockoutRemaining {
    final until = _vaultLockedOutUntil;
    if (until == null) return Duration.zero;
    final remaining = until.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool get isVaultLockedOut => vaultLockoutRemaining > Duration.zero;

  DateTime? _vaultLockedOutUntil;
  static const _vaultAttemptsBeforeThrottle = 3;
  static const _vaultMaxLockout = Duration(minutes: 5);

  void _applyVaultLockout() {
    if (_failedPinAttempts < _vaultAttemptsBeforeThrottle) return;
    final overshoot = _failedPinAttempts - _vaultAttemptsBeforeThrottle;
    final seconds = 5 * (1 << overshoot.clamp(0, 6));
    final delay = Duration(seconds: seconds) > _vaultMaxLockout
        ? _vaultMaxLockout
        : Duration(seconds: seconds);
    _vaultLockedOutUntil = DateTime.now().add(delay);
  }

  Future<bool> checkVaultPin(String pin) async {
    if (isVaultLockedOut) {
      final seconds = vaultLockoutRemaining.inSeconds + 1;
      setStatus('statusTooManyAttempts', {'seconds': '$seconds'});
      notifyListeners();
      return false;
    }
    var unlocked = await VaultEncryptionService.unlockWithPin(pin);
    if (!unlocked && pin == _vaultPin) {
      // One-time migration from the legacy plaintext PIN storage.
      await VaultEncryptionService.configurePin(pin);
      await _store.writeVaultPin(null);
      _vaultPin = null;
      unlocked = true;
      await _migrateLegacyVaultFiles();
    }
    if (unlocked) {
      await _restorePrivateMetadata();
      isVaultLocked = false;
      touchVault();
      isDecoySession = false;
      _failedPinAttempts = 0;
      _vaultLockedOutUntil = null;
      notifyListeners();
      return true;
    }
    var decoyUnlocked = await VaultEncryptionService.unlockWithDecoyPin(pin);
    if (!decoyUnlocked && pin == _decoyVaultPin) {
      await VaultEncryptionService.configureDecoyPin(pin);
      await _store.writeDecoyVaultPin(null);
      _decoyVaultPin = null;
      decoyUnlocked = true;
    }
    if (decoyUnlocked) {
      isVaultLocked = false;
      touchVault();
      isDecoySession = true;
      _failedPinAttempts = 0;
      _vaultLockedOutUntil = null;
      notifyListeners();
      return true;
    }
    VaultEncryptionService.lock();
    isVaultLocked = true;
    isDecoySession = false;
    _failedPinAttempts++;
    if (_failedPinAttempts == _vaultAttemptsBeforeThrottle) {
      unawaited(VaultCameraService.captureIntruderSelfie());
    }
    _applyVaultLockout();
    if (isVaultLockedOut) {
      status =
          'Too many attempts. Try again in '
          '${vaultLockoutRemaining.inSeconds + 1}s.';
    }
    notifyListeners();
    return false;
  }

  Future<void> setVaultPin(String pin) async {
    bool isNewVault;
    try {
      isNewVault = await VaultEncryptionService.configurePin(pin);
    } catch (e) {
      await VaultEncryptionService.deleteVaultKeys();
      isNewVault = await VaultEncryptionService.configurePin(pin);
    }

    // A brand-new master key leaves any previous metadata index encrypted with
    // a key that no longer exists anywhere. Keeping it around meant
    // _restorePrivateMetadata failed to decrypt it, flagged the index unhealthy
    // and then refused every future vault write — bricking the vault with no
    // way back. Clearing it here is safe precisely because nothing can read it.
    if (isNewVault) {
      await VaultEncryptionService.resetPrivateDownloadIndex();
      _privateMetadata.clear();
    }

    _vaultPin = null;
    await _store.writeVaultPin(null);
    isVaultLocked = false;
    isDecoySession = false;
    touchVault();
    await _restorePrivateMetadata();
    notifyListeners();
  }

  /// Whether the encrypted metadata index failed to load this session.
  ///
  /// While false, vault writes are refused so a half-readable index is never
  /// overwritten. [recoverVaultMetadataIndex] is the way out.
  bool get vaultMetadataNeedsRecovery => !_privateMetadataIndexHealthy;

  /// Rebuilds the metadata index from what is currently known and re-enables
  /// vault writes.
  ///
  /// This is deliberately explicit rather than automatic: it discards whatever
  /// the unreadable index held, so it belongs behind a user action once they
  /// accept that some vault entries may lose their title/thumbnail. The
  /// encrypted media files themselves are never touched.
  Future<bool> recoverVaultMetadataIndex() async {
    if (!VaultEncryptionService.isUnlocked) {
      setStatus('statusUnlockVaultFirst');
      notifyListeners();
      return false;
    }
    try {
      await VaultEncryptionService.resetPrivateDownloadIndex();
      _privateMetadataIndexHealthy = true;
      // Re-seed from the downloads still marked private so nothing recoverable
      // is thrown away.
      for (final item in _downloads.where((item) => item.isPrivate)) {
        if (item.url.isNotEmpty) {
          _privateMetadata.putIfAbsent(item.id, () => item);
        }
      }
      await _persistPrivateMetadata();
      setStatus('statusVaultIndexRebuilt');
      notifyListeners();
      return true;
    } catch (error) {
      _privateMetadataIndexHealthy = false;
      setStatus('statusVaultIndexRebuildFailed', {'error': _cleanError(error)});
      flow = DuckFlow.error;
      notifyListeners();
      return false;
    }
  }

  Future<void> _restorePrivateMetadata() async {
    List<Map<String, dynamic>> encryptedEntries = const [];
    try {
      encryptedEntries =
          await VaultEncryptionService.readPrivateDownloadIndex();
      _privateMetadataIndexHealthy = true;
    } catch (error, stackTrace) {
      _privateMetadataIndexHealthy = false;
      reportError(error, stackTrace, reason: 'vault-index-restore');
    }
    for (final entry in encryptedEntries) {
      try {
        final item = DownloadItem.fromJson(entry);
        if (item.isPrivate) _privateMetadata[item.id] = item;
      } catch (_) {}
    }
    for (final item in _downloads.where((item) => item.isPrivate)) {
      if (item.url.isNotEmpty)
        _privateMetadata.putIfAbsent(item.id, () => item);
    }
    _downloads = [
      for (final item in _downloads)
        if (item.isPrivate) _privateMetadata[item.id] ?? item else item,
    ];
    if (_privateMetadataIndexHealthy) {
      try {
        await _persistPrivateMetadata();
      } catch (error, stackTrace) {
        reportError(error, stackTrace, reason: 'vault-index-save');
      }
    }
  }

  Future<void> _persistPrivateMetadata() async {
    if (!VaultEncryptionService.isUnlocked) return;
    if (!_privateMetadataIndexHealthy) {
      throw StateError(
        'Vault metadata needs recovery before it can be changed.',
      );
    }
    final entries = [
      for (final item in _privateMetadata.values)
        if (item.url.isNotEmpty) item.toJson(),
    ];
    await VaultEncryptionService.writePrivateDownloadIndex(entries);
    // Re-apply what is private on top of what is actually stored, rather than
    // writing this object's copy of the list back over it. The copy goes stale
    // the moment another download saves, and writing it back took that
    // download's row with it.
    _downloads = await _store.rewrite(
      (stored) => [for (final item in stored) _privateMetadata[item.id] ?? item],
    );
    _mergePrivateMetadata();
  }

  void _mergePrivateMetadata() {
    _downloads = [
      for (final item in _downloads)
        if (item.isPrivate) _privateMetadata[item.id] ?? item else item,
    ];
  }

  Future<void> _migrateLegacyVaultFiles() async {
    for (final item in List<DownloadItem>.from(_downloads)) {
      if (!item.isPrivate || item.filePath == null) continue;
      if (await VaultEncryptionService.isEncryptedFile(item.filePath!))
        continue;
      final encryptedPath = await _files.moveFileToVault(
        currentPath: item.filePath!,
        filename: p.basename(item.filePath!),
      );
      await _saveItem(item.copyWith(filePath: encryptedPath));
    }
  }

  Future<void> setDecoyVaultPin(String pin) async {
    await VaultEncryptionService.configureDecoyPin(pin);
    _decoyVaultPin = null;
    await _store.writeDecoyVaultPin(null);
    notifyListeners();
  }

  Future<void> toggleBiometricEnabled(bool enabled) async {
    _biometricEnabled = enabled;
    await _store.writeBiometricEnabled(enabled);
    notifyListeners();
  }

  /// How long the vault may sit unused before it locks itself.
  ///
  /// Backgrounding the app already locks it. This covers the other way a vault
  /// is left open: the phone is put down, face up, on a table.
  static const vaultIdleTimeout = Duration(minutes: 2);

  Timer? _vaultIdleTimer;

  /// Restarts the idle countdown. Called whenever the user touches the vault.
  void touchVault() {
    _vaultIdleTimer?.cancel();
    if (isVaultLocked) return;
    _vaultIdleTimer = Timer(vaultIdleTimeout, () {
      // Never lock out from under something that is playing. Watching a long
      // video is not idleness, and a vault that locks mid-scene is worse than
      // one that stays open a few minutes longer.
      if (playerItem != null || audioPlayer.playing) {
        touchVault();
        return;
      }
      lockVault();
    });
  }

  void lockVault() {
    _vaultIdleTimer?.cancel();
    _vaultIdleTimer = null;
    VaultEncryptionService.lock();
    isVaultLocked = true;
    isDecoySession = false;
    notifyListeners();
  }

  Future<bool> unlockVaultBiometric() async {
    if (!await VaultEncryptionService.unlockWithDeviceKey()) return false;
    await _restorePrivateMetadata();
    isVaultLocked = false;
    isDecoySession = false;
    touchVault();
    notifyListeners();
    return true;
  }

  Future<void> toggleFavorite(DownloadItem item) async {
    DuckHaptics.toggle();
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

  Future<bool> moveItemToVault(DownloadItem item) async {
    if (!VaultEncryptionService.isUnlocked) {
      setStatus('statusUnlockVaultBeforeMove');
      notifyListeners();
      return false;
    }
    final path = item.filePath;
    if (path == null) {
      setStatus('statusFileNotLocal');
      notifyListeners();
      return false;
    }

    try {
      final ext = path.contains('.')
          ? path.split('.').last.toLowerCase()
          : (item.isAudio
                ? 'mp3'
                : (item.type == DownloadType.image ? 'jpg' : 'mp4'));
      final filename = item.title.toLowerCase().endsWith('.$ext')
          ? item.title
          : '${item.title}.$ext';
      final vaultPath = await _files.copyFileToVault(
        currentPath: path,
        filename: filename,
      );
      try {
        await _saveItem(item.copyWith(isPrivate: true, filePath: vaultPath));
      } catch (_) {
        await _files.deleteFile(vaultPath);
        rethrow;
      }
      try {
        await _files.deleteFile(path);
      } catch (_) {
        status =
            'File was secured, but the original copy could not be removed.';
        notifyListeners();
        return false;
      }
      setStatus('statusMovedToVault');
      notifyListeners();
      return true;
    } catch (error) {
      setStatus('statusMoveToVaultFailed', {'error': _cleanError(error)});
      flow = DuckFlow.error;
      notifyListeners();
      return false;
    }
  }

  Future<void> moveItemFromVault(DownloadItem item) async {
    final path = item.filePath;
    if (path == null) throw Exception('File not available locally.');
    final ext = path.contains('.')
        ? path.split('.').last.toLowerCase()
        : (item.isAudio
              ? 'mp3'
              : (item.type == DownloadType.image ? 'jpg' : 'mp4'));
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
    setStatus('statusRestoredFromVault');
    notifyListeners();
  }

  Future<void> importLocalFileToVault(
    String localPath,
    DownloadType type,
  ) async {
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

  Future<void> convertVideoToAudio(
    DownloadItem item,
    String format,
    int bitrate,
  ) async {
    final originalPath = item.filePath;
    if (originalPath == null) throw Exception('Video file path is empty.');

    busy = true;
    flow = DuckFlow.extracting;
    setStatus('statusConvertingToAudio');
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
      setStatus('statusConversionComplete');
      unawaited(
        _notifications.showDownloadComplete(
          id: audioItem.id.hashCode,
          title: audioItem.title,
          type: 'Audio',
          downloadId: audioItem.id,
        ),
      );
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

  Future<void> createGifFromVideo(
    DownloadItem item,
    double startTime,
    double duration,
    int width,
  ) async {
    final originalPath = item.filePath;
    if (originalPath == null) throw Exception('Video file path is empty.');

    busy = true;
    flow = DuckFlow.extracting;
    setStatus('statusCreatingGif');
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
      setStatus('statusGifCreated');
      unawaited(
        _notifications.showDownloadComplete(
          id: gifItem.id.hashCode,
          title: gifItem.title,
          type: 'Image',
          downloadId: gifItem.id,
        ),
      );
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

  Future<void> shareLastDownloadedItem() async {
    final item = lastDownloadedItem;
    if (item == null || item.filePath == null) return;
    if (item.isPrivate) {
      setStatus('statusPrivateCannotShare');
      notifyListeners();
      return;
    }
    await _files.shareFile(item.filePath);
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
    setStatus('statusPlaylistCreated', {'name': p.name});
    notifyListeners();
  }

  Future<void> deletePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    await _store.writePlaylists(_playlists);
    _playlists = _store.readPlaylists();
    setStatus('statusPlaylistDeleted');
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
        setStatus('statusAddedToPlaylist');
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
        setStatus('statusRemovedFromPlaylist');
        notifyListeners();
      }
    }
  }

  Future<void> openPlayer(
    DownloadItem item, {
    List<DownloadItem>? galleryItems,
    List<DownloadItem>? queueItems,
  }) async {
    if (item.isPrivate && isVaultLocked) {
      setStatus('statusUnlockVaultFirst');
      notifyListeners();
      return;
    }

    // Only vault media needs decrypting to a temp file first. Everything else
    // opens on this frame rather than a microtask later: awaiting here meant
    // playerItem was still null immediately after the call, which delayed the
    // player by a frame and left callers unable to rely on it synchronously.
    // (_clearPlayerTemp nulls _playerTempPath synchronously, so letting the
    // delete finish in the background is safe.)
    if (!(item.isPrivate && !item.isImage)) {
      unawaited(_clearPlayerTemp());
      playerItem = item;
      playerGalleryItems = galleryItems;
      _audioQueueSource = queueItems;
      notifyListeners();
      return;
    }

    await _clearPlayerTemp();
    var playableItem = item;
    if (item.isPrivate && !item.isImage) {
      try {
        final info = await _getEffectivePathAndFileName(item);
        _playerTempPath = info['path'];
        playableItem = item.copyWith(
          filePath: _playerTempPath,
          isPrivate: false,
        );
      } catch (error) {
        setStatus('statusVaultOpenFailed', {'error': _cleanError(error)});
        flow = DuckFlow.error;
        notifyListeners();
        return;
      }
    }

    playerItem = playableItem;
    playerGalleryItems = galleryItems;
    _audioQueueSource = queueItems;
    notifyListeners();
  }

  Future<void> _clearPlayerTemp() async {
    final path = _playerTempPath;
    _playerTempPath = null;
    if (path == null) return;
    try {
      await File(path).delete();
    } catch (_) {}
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
        unawaited(openPlayer(item));
        return;
      }
    }
  }

  void closePlayer() {
    unawaited(_clearPlayerTemp());
    playerItem = null;
    playerGalleryItems = null;
    _audioQueueSource = null;
    notifyListeners();
  }

  Future<void> _extractUrlOrBatch(String url) async {
    lastAttemptedUrl = url;
    _resetForNewExtraction();
    lastDownloadedItem = null;

    var cleanUrl = url.trim();

    final verdict = await _isAdultUrl(cleanUrl);
    if (verdict == _AdultVerdict.blocked) {
      isAdultContentBlocked = true;
      notifyListeners();
      throw Exception('BLOCKED_ADULT_CONTENT');
    }
    if (verdict == _AdultVerdict.unverified) {
      throw Exception('ADULT_CHECK_UNAVAILABLE');
    }

    final hasVideoAndList =
        cleanUrl.contains('v=') &&
        (cleanUrl.contains('list=') || cleanUrl.contains('/playlist'));
    var isPlaylist =
        cleanUrl.contains('list=') || cleanUrl.contains('/playlist');

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
      setStatus('statusChooseVideos');
    } else if (isPlaylist) {
      flow = DuckFlow.extracting;
      setStatus('statusExtractingPlaylist');
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
          setStatus('statusChooseVideos');
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
      setStatus('statusChooseVideos');
    } else {
      if (!_isPublicMediaCandidate(cleanUrl)) {
        throw Exception('Copy a public social media link first.');
      }

      // ── YouTube: extract on-device, never through the backend ─────────────
      // The backend runs from a datacentre IP, which YouTube bot-checks almost
      // immediately. youtube_explode runs on the user's own connection, so it
      // keeps working and it also returns the real quality ladder rather than
      // whatever the server managed to negotiate.
      if (YouTubeExplodeService.isYouTubeUrl(cleanUrl)) {
        flow = DuckFlow.extracting;
        setStatus('statusFetchingYouTube');
        notifyListeners();
        try {
          final ytMeta = await _ytExplode.extractMetadata(cleanUrl);
          if (ytMeta != null && ytMeta.qualities.isNotEmpty) {
            metadata = ytMeta;
            selectedType = _selectDefaultDownloadType(ytMeta, cleanUrl);
            quality = _firstQuality(ytMeta, selectedType);
            flow = DuckFlow.ready;
            setStatus(
              selectedType == DownloadType.audio
                  ? 'statusChooseAudioFormat'
                  : 'statusChooseVideoOrAudio',
            );
            return;
          }
          // Deliberately says nothing about age or restrictions. The old
          // wording listed "age-restricted" as a possibility, and the sign-in
          // heuristic below matched that phrase — in a sentence the app wrote
          // itself, for a video it had failed to even identify. Signing in
          // could not change the outcome, so the prompt returned every time.
          throw Exception(
            'Could not read this YouTube video.',
          );
        } catch (error) {
          if (_shouldAskToSignIn(cleanUrl, error) && _requestLogin(cleanUrl)) {
            return;
          }
          rethrow;
        }
      }

      // ── Reddit: resolve on-device from the public JSON endpoint ──────────
      // v.redd.it serves DASH, so the post's own metadata is the only place
      // the matching audio track is discoverable. Doing it here also means the
      // NSFW flag has already been checked by _isAdultUrl above.
      if (RedditService.isRedditUrl(cleanUrl)) {
        try {
          final post = await _reddit.fetchPost(cleanUrl);
          final media = post == null
              ? null
              : _reddit.buildMetadata(cleanUrl, post);
          if (media != null) {
            metadata = media;
            if (post!.isVideo) {
              selectedType = DownloadType.video;
              quality = _firstQuality(media, DownloadType.video);
              flow = DuckFlow.ready;
              setStatus('statusChooseVideoOrAudio');
            } else {
              selectedType = DownloadType.image;
              quality = _firstQuality(media, DownloadType.image);
              flow = DuckFlow.ready;
              setStatus('statusTapDownloadForImage');
            }
            return;
          }
        } catch (error) {
          debugPrint('Reddit extraction failed, falling back: $error');
        }
        // Fall through to the backend for galleries and text posts.
      }

      if (MetaPostService.handles(cleanUrl)) {
        await _extractMetaPost(cleanUrl);
        return;
      }
      try {
        final media = await _api.extract(cleanUrl);
        metadata = media;
        if (_isImageMetadata(media) || _looksLikeImageUrl(cleanUrl)) {
          selectedType = DownloadType.image;
          quality = _firstQuality(media, DownloadType.image);
          flow = DuckFlow.ready;
          setStatus('statusTapDownloadForImage');
        } else {
          selectedType = _selectDefaultDownloadType(media, cleanUrl);
          quality = _firstQuality(media, selectedType);
          flow = DuckFlow.ready;
          setStatus(
            selectedType == DownloadType.audio
                ? 'statusChooseAudioFormat'
                : 'statusChooseVideoOrAudio',
          );
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
            setStatus('statusChooseImages');
          } else {
            rethrow;
          }
        } catch (fallbackError) {
          if ((_shouldAskToSignIn(cleanUrl, error) ||
                  _shouldAskToSignIn(cleanUrl, fallbackError)) &&
              _requestLogin(cleanUrl)) {
            return;
          }
          rethrow;
        }
      }
    }
  }

  /// Reads an Instagram post, trying the device before the server.
  ///
  /// Three tiers, in this order for a reason. Meta answers a request from a
  /// datacentre address as a stranger no matter whose cookies it carries, so
  /// the phone — on a residential connection, with the user's own session —
  /// is the only one of the two that reliably gets an answer. The backend is
  /// still worth asking when the device call fails, and the page itself is the
  /// last resort when both do.
  Future<void> _extractMetaPost(String cleanUrl) async {
    Object? deviceError;
    try {
      _presentMetaPost(await _meta.fetchPost(cleanUrl), cleanUrl);
      return;
    } catch (error, stackTrace) {
      deviceError = error;
      if (error is! MetaAuthRequired && error is! MetaPostUnavailable) {
        reportError(error, stackTrace, reason: 'instagram-on-device');
      }
    }

    // A post that Instagram itself says is gone will not be found by anything
    // else either, and pretending otherwise costs the user two more timeouts.
    if (deviceError is MetaPostUnavailable) {
      throw Exception(deviceError.toString());
    }

    try {
      final playlist = await _api.extractPlaylist(cleanUrl);
      if (playlist.items.isNotEmpty) {
        _presentMetaPlaylist(playlist, cleanUrl);
        return;
      }
    } catch (_) {
      // Falls through to the page.
    }

    try {
      final scraped = await _meta.fetchPostFromPage(cleanUrl);
      _presentMetaPost(scraped, cleanUrl);
      return;
    } catch (error, stackTrace) {
      if (error is! MetaAuthRequired && error is! MetaPostUnavailable) {
        reportError(error, stackTrace, reason: 'instagram-page-read');
      }
    }

    // Only now is a sign-in worth offering, and only if a session is actually
    // what was missing. Offering it for every failure is what put a signed-in
    // user in a loop: sign in, fail, be asked to sign in again.
    if (deviceError is MetaAuthRequired &&
        !_justSignedIn &&
        _requestLogin(cleanUrl)) {
      return;
    }
    throw Exception(deviceError.toString());
  }

  /// Puts a post on screen: one item becomes options, several become a batch.
  void _presentMetaPost(MetaPost post, String sourceUrl) {
    _metaPost = post;
    // The real platform, not a hardcoded one: the same code reads Threads,
    // and a Threads download filed under "Instagram" is a lie in the library.
    _metaPlatform = MetaPostService.platformOf(sourceUrl);
    batchPlatform = _metaPlatformLabel;
    lastAttemptedUrl = sourceUrl;

    if (post.isSingle) {
      final media = post.items.single;
      metadata = MediaMetadata(
        // The direct CDN URL, so the file downloads on this device rather than
        // being fetched a second time by the backend on the user's behalf.
        url: media.url,
        title: post.title,
        platform: _metaPlatformLabel,
        thumbnail: media.thumbnail ?? media.url,
        qualities: [
          FormatInfo(
            id: 'best',
            label: media.isVideo
                ? (media.height == null ? 'Original' : '${media.height}p')
                : 'Original Image',
            ext: media.isVideo ? 'mp4' : 'jpg',
            width: media.width,
            height: media.height,
          ),
        ],
        // A Reel can also be saved as sound, and as its cover picture — the
        // Image chip on a video post means the cover.
        audioFormats: media.isVideo
            ? const [FormatInfo(id: 'mp3', label: 'MP3 192kbps', ext: 'mp3')]
            : const [],
      );
      selectedType = media.isVideo ? DownloadType.video : DownloadType.image;
      quality = metadata!.qualities.first.label;
      flow = DuckFlow.ready;
      setStatus(
        media.isVideo ? 'statusChooseVideoOrAudio' : 'statusTapDownloadForImage',
      );
      return;
    }

    batchTitle = post.title;
    batchItems = [
      for (var i = 0; i < post.items.length; i++)
        PlaylistItem(
          url: post.items[i].url,
          title: '${post.title} ${i + 1}',
          thumbnail: post.items[i].thumbnail ?? post.items[i].url,
          width: post.items[i].width,
          height: post.items[i].height,
          source: 'instagram_device',
          isVideo: post.items[i].isVideo,
        ),
    ];
    // A mixed post opens on "everything as it is". Opening on one type means
    // the careless tap downloads four copies of the wrong thing.
    selectedType = post.hasVideo ? DownloadType.video : DownloadType.image;
    quality = 'Best';
    flow = DuckFlow.ready;
    setStatus('statusChooseImages');
  }

  /// The same presentation, for a post the backend read instead.
  void _presentMetaPlaylist(
    PlaylistExtractResponse playlist,
    String sourceUrl,
  ) {
    _presentMetaPost(
      MetaPost(
        shortcode: MetaPostService.shortcodeOf(sourceUrl) ?? '',
        title: playlist.title.isEmpty ? 'Instagram Post' : playlist.title,
        items: [
          for (final item in playlist.items)
            MetaMedia(
              url: item.url,
              isVideo: item.isVideo,
              width: item.width,
              height: item.height,
              thumbnail: item.thumbnail,
            ),
        ],
      ),
      sourceUrl,
    );
  }

  /// True when [url] is a file this device already knows how to fetch itself.
  bool _isDirectMetaMedia(String url) {
    final post = _metaPost;
    if (post == null) return false;
    return post.items.any((item) => item.url == url);
  }

  Future<void> _playQuack() async {
    try {
      await _sfxPlayer.setAsset(DuckAssets.quackTap);
      await _sfxPlayer.play();
    } catch (_) {}
  }

  /// Refuses a second job while one is already running, and says so.
  ///
  /// Every one of these guards used to be a bare `return`. The user pasted a
  /// link, tapped download, or shared something from another app, and nothing
  /// happened at all — no message, no spinner, no error. A shared link in
  /// particular simply vanished, which reads as the app being broken rather
  /// than busy.
  bool _rejectIfBusy() {
    if (!busy) return false;
    setStatus('statusStillBusy');
    notifyListeners();
    return true;
  }

  /// Clears everything the previous link left behind.
  ///
  /// There are four ways into an extraction — the paste button, the clipboard
  /// banner, a shared link and a typed URL — and each used to clear its own
  /// idea of what needed clearing. They had already drifted: only the paste
  /// button dropped the held Instagram post, so a link arriving any other way
  /// left the previous post's files still matching `_isDirectMetaMedia`
  /// and taking a download branch meant for a post that was no longer open.
  void _resetForNewExtraction() {
    metadata = null;
    batchItems = null;
    batchTitle = null;
    batchPlatform = null;
    _metaPost = null;
    _metaPlatform = null;
    _loginRequest = null;
  }

  Future<void> pasteAndExtract() async {
    if (_rejectIfBusy()) return;
    DuckHaptics.tap();
    unawaited(_playQuack());
    busy = true;
    flow = DuckFlow.extracting;
    setStatus('statusCheckingLink');
    _resetForNewExtraction();
    notifyListeners();

    try {
      final url = await _clipboard.readText();
      if (url == null) {
        throw Exception('Copy a public social media link first.');
      }
      await _extractUrlOrBatch(url);
    } catch (error) {
      flow = DuckFlow.error;
      _status = _errorStatus(error);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> extractUrl(String url, {bool afterSignIn = false}) async {
    if (_rejectIfBusy()) return;
    busy = true;
    _justSignedIn = afterSignIn;
    flow = DuckFlow.extracting;
    setStatus('statusCheckingLink');
    _resetForNewExtraction();
    notifyListeners();

    try {
      await _extractUrlOrBatch(url);
    } catch (error) {
      flow = DuckFlow.error;
      _status = _errorStatus(error);
    } finally {
      busy = false;
      _justSignedIn = false;
      notifyListeners();
    }
  }

  Future<void> startDownload() async {
    final media = metadata;
    if (media == null || busy) return;
    busy = true;
    flow = DuckFlow.downloading;
    setStatus('statusDownloading');
    metadata = null;
    notifyListeners();

    try {
      // Instagram: the extraction already produced the direct CDN URL, so the
      // file comes straight to this device. Posting it to the backend would
      // ask the server to fetch a public file the phone can reach itself, on
      // a connection Meta is more likely to refuse.
      if (_isDirectMetaMedia(media.url)) {
        await _startMetaDownload(media);
        return;
      }

      // 1. YouTube: Download directly on-device using YouTubeExplodeService!
      // This runs on the user's residential connection (never blocked by datacenter IP checks),
      // downloads at maximum speed directly to the phone, and avoids 403 Forbidden.
      final isYouTube = YouTubeExplodeService.isYouTubeUrl(media.url) ||
          media.platform.toLowerCase() == 'youtube';
      if (isYouTube) {
        await _startYouTubeExplodeDownload(media);
        return;
      }

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

      if (cobaltUrl != null && cobaltUrl.isNotEmpty) {
        await _startCobaltDownload(media, cobaltUrl);
        return;
      }

      final type = selectedType;
      final chosenQuality = quality;
      final stripAudio = removeMusic;
      await _enqueueDownload(
        placeholder: DownloadItem(
          id: _newLocalDownloadId(),
          url: media.url,
          title: media.title,
          thumbnail: media.thumbnail,
          platform: media.platform,
          quality: chosenQuality,
          type: type,
          createdAt: DateTime.now(),
          status: DownloadStatus.queued,
          progress: 0,
          favorite: false,
          isPrivate: downloadDirectToVault,
        ),
        // Captured rather than read at start time: the user is free to change
        // the type and quality pickers while this waits its turn, and the job
        // must download what they actually asked for.
        begin: () => _api.startDownload(
          url: media.url,
          type: type,
          quality: chosenQuality,
          removeMusic: stripAudio,
          premiumNoWatermark: true,
        ),
      );
    } catch (error) {
      flow = DuckFlow.error;
      _status = _errorStatus(error);
      if (_isLoginRequiredError(error.toString()) &&
          !_justSignedIn &&
          _requestLogin(media.url)) {
        return;
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// One item of an Instagram carousel, fetched by this device.
  ///
  /// [type] is already per-item when the user chose "everything as it is", so
  /// a photo in a mixed post saves as a photo and the video beside it saves as
  /// a video.
  Future<void> _startMetaBatchItem({
    required String url,
    required String title,
    required PlaylistItem? item,
    required DownloadType type,
  }) async {
    final itemId = _newLocalDownloadId();
    var entry = DownloadItem(
      id: itemId,
      url: url,
      title: title.isEmpty ? _metaPlatformLabel : title,
      thumbnail: item?.thumbnail ?? url,
      platform: _metaPlatformLabel,
      quality: 'Best',
      type: type,
      createdAt: DateTime.now(),
      status: DownloadStatus.downloading,
      progress: 0,
      favorite: false,
      isPrivate: downloadDirectToVault,
    );
    await _saveItem(entry);

    try {
      final filePath = await _ytExplode.downloadStream(
        streamUrl: url,
        title: entry.title,
        type: type,
        ext: type == DownloadType.image ? 'jpg' : 'mp4',
        onProgress: (received, total) async {
          if (total <= 0) return;
          await _publishProgress(
            entry,
            ((received / total) * 100).clamp(0, 100).toInt(),
          );
        },
      );

      entry = entry.copyWith(
        filePath: filePath,
        progress: 100,
        status: DownloadStatus.completed,
      );
      if (entry.isPrivate) {
        entry = entry.copyWith(
          filePath: await _files.moveFileToVault(
            currentPath: filePath,
            filename: p.basename(filePath),
          ),
        );
      }
      await _saveItem(entry);
      if (!entry.isPrivate && autoSaveVideos) {
        entry = await _trySaveMediaAfterDownload(entry);
      }
      lastDownloadedItem = entry;
    } catch (error) {
      await _saveItem(entry.copyWith(status: DownloadStatus.failed));
      rethrow;
    }
  }

  /// Downloads one Instagram item as whichever of the three the user picked.
  ///
  /// On a Reel the Image chip means the cover frame and the Audio chip means
  /// the sound, so the same post answers all three without a second trip to
  /// Instagram.
  Future<void> _startMetaDownload(MediaMetadata media) async {
    final post = _metaPost;
    final item = post?.items.firstWhere(
      (candidate) => candidate.url == media.url,
      orElse: () => MetaMedia(url: media.url, isVideo: true),
    );
    if (item == null) return;

    if (selectedType == DownloadType.image) {
      await _startCobaltDownload(
        media,
        item.isVideo ? (item.thumbnail ?? item.url) : item.url,
      );
      return;
    }
    if (selectedType == DownloadType.audio && item.isVideo) {
      await _startMetaAudioDownload(media, item);
      return;
    }
    await _startCobaltDownload(media, item.url);
  }

  /// Saves a Reel as sound: fetch the video, keep the audio, drop the file.
  ///
  /// Instagram serves no audio-only rendition, so the choice is this or no
  /// Audio chip at all on a platform where saving the sound is most of why
  /// people download Reels.
  Future<void> _startMetaAudioDownload(
    MediaMetadata media,
    MetaMedia item,
  ) async {
    final itemId = _newLocalDownloadId();
    var entry = DownloadItem(
      id: itemId,
      url: media.url,
      title: media.title,
      thumbnail: item.thumbnail ?? media.thumbnail,
      platform: _metaPlatformLabel,
      quality: quality,
      type: DownloadType.audio,
      createdAt: DateTime.now(),
      status: DownloadStatus.downloading,
      progress: 0,
      favorite: false,
      isPrivate: downloadDirectToVault,
    );
    await _saveItem(entry);
    activeId = itemId;

    String? videoPath;
    try {
      videoPath = await _ytExplode.downloadStream(
        streamUrl: item.url,
        title: media.title,
        type: DownloadType.video,
        ext: 'mp4',
        onProgress: (received, total) async {
          if (total <= 0) return;
          // Stops at 90: the conversion after this is not instant, and a bar
          // that sat at 100% while ffmpeg ran read as a finished download that
          // had produced no file.
          await _publishProgress(
            entry,
            ((received / total) * 90).clamp(0, 90).toInt(),
          );
        },
      );

      setStatus('statusConvertingToAudio');
      await _publishProgress(entry, 95, status: DownloadStatus.processing);
      final audioPath = await ConversionService.convertVideoToAudio(
        inputPath: videoPath,
        format: 'mp3',
        bitrate: 192,
      );

      entry = entry.copyWith(
        filePath: audioPath,
        progress: 100,
        status: DownloadStatus.completed,
      );
      if (entry.isPrivate) {
        entry = entry.copyWith(
          filePath: await _files.moveFileToVault(
            currentPath: audioPath,
            filename: p.basename(audioPath),
          ),
        );
      }
      await _saveItem(entry);
      if (!entry.isPrivate && autoSaveVideos) {
        entry = await _trySaveMediaAfterDownload(entry);
      }

      lastDownloadedItem = entry;
      flow = DuckFlow.success;
      setStatus('statusConversionComplete');
      unawaited(
        _notifications.showDownloadComplete(
          id: entry.id.hashCode,
          title: entry.title,
          type: 'Audio',
          downloadId: entry.id,
        ),
      );
    } catch (error) {
      await _saveItem(entry.copyWith(status: DownloadStatus.failed));
      flow = DuckFlow.error;
      _status = _errorStatus(error);
    } finally {
      // The video was only ever a means to the sound.
      if (videoPath != null) {
        try {
          final file = File(videoPath);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      busy = false;
      notifyListeners();
    }
  }

  /// Downloads media via Cobalt URL directly on-device.
  Future<void> _startCobaltDownload(
    MediaMetadata media,
    String downloadUrl,
  ) async {
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
          await _publishProgress(item, progress);
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
        if (item.isPrivate) {
          final vaultPath = await _files.moveFileToVault(
            currentPath: filePath,
            filename: p.basename(filePath),
          );
          item = item.copyWith(filePath: vaultPath);
        }
        await _saveItem(item);

        if (!item.isPrivate && autoSaveVideos) {
          item = await _trySaveMediaAfterDownload(item);
        }
      }

      lastDownloadedItem = item;
      flow = DuckFlow.success;
      status =
          ((item.isVideo && item.savedToGallery) ||
              (item.isAudio && item.savedToMusic))
          ? 'Download complete and saved externally'
          : 'Download complete';

      unawaited(
        _notifications.showDownloadComplete(
          id: item.id.hashCode,
          title: item.title,
          type: item.isVideo ? 'Video' : 'Audio',
          downloadId: item.id,
        ),
      );
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
        final type = selectedType;
        final chosenQuality = quality;
        final stripAudio = removeMusic;
        await _enqueueDownload(
          placeholder: DownloadItem(
            id: _newLocalDownloadId(),
            url: media.url,
            title: media.title,
            thumbnail: media.thumbnail,
            platform: media.platform,
            quality: chosenQuality,
            type: type,
            createdAt: DateTime.now(),
            status: DownloadStatus.queued,
            progress: 0,
            favorite: false,
            isPrivate: downloadDirectToVault,
          ),
          begin: () => _api.startDownload(
            url: media.url,
            type: type,
            quality: chosenQuality,
            removeMusic: stripAudio,
            premiumNoWatermark: true,
          ),
        );
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
            await _publishProgress(item, progress);
          },
          onTranscoding: () async {
            setStatus('statusConvertingToM4a');
            await _publishProgress(
              item,
              99,
              status: DownloadStatus.processing,
            );
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
            await _publishProgress(item, progress);
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
        if (item.isPrivate) {
          final vaultPath = await _files.moveFileToVault(
            currentPath: filePath,
            filename: p.basename(filePath),
          );
          item = item.copyWith(filePath: vaultPath);
        }
        await _saveItem(item);

        if (!item.isPrivate && autoSaveVideos) {
          item = await _trySaveMediaAfterDownload(item);
        }
      }

      lastDownloadedItem = item;
      flow = DuckFlow.success;
      status =
          ((item.isVideo && item.savedToGallery) ||
              (item.isAudio && item.savedToMusic))
          ? 'Download complete and saved externally'
          : 'Download complete';

      unawaited(
        _notifications.showDownloadComplete(
          id: item.id.hashCode,
          title: item.title,
          type: item.isVideo ? 'Video' : 'Audio',
          downloadId: item.id,
        ),
      );
    } catch (error) {
      item = item.copyWith(status: DownloadStatus.failed);
      await _saveItem(item);
      flow = DuckFlow.error;
      setStatus('statusYouTubeFailed', {'error': _cleanError(error)});
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
    FormatInfo? preferredFormat,
  }) async {
    // 1. Extract metadata on-device to get streams
    final ytMeta = await _ytExplode.extractMetadata(url);
    if (ytMeta == null || ytMeta.qualities.isEmpty) {
      throw Exception('Could not extract streams for YouTube video.');
    }

    // 2. Respect the quality selected by the user when it is still available.
    final allFormats = type == DownloadType.video
        ? ytMeta.qualities
        : ytMeta.audioFormats;
    if (allFormats.isEmpty) {
      throw Exception('No compatible quality format found.');
    }
    final format = preferredFormat == null
        ? allFormats.first
        : allFormats.firstWhere(
            (candidate) =>
                candidate.id == preferredFormat.id ||
                candidate.label == preferredFormat.label,
            orElse: () => allFormats.first,
          );
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
      isPrivate: downloadDirectToVault,
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
              await _publishProgress(item, progress);
            },
            onTranscoding: () async {
              await _publishProgress(
                item,
                99,
                status: DownloadStatus.processing,
              );
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
              await _publishProgress(item, progress);
            },
          );
        }
        item = item.copyWith(
          filePath: filePath,
          progress: 100,
          status: DownloadStatus.completed,
        );
        if (item.isPrivate) {
          final vaultPath = await _files.moveFileToVault(
            currentPath: filePath,
            filename: p.basename(filePath),
          );
          item = item.copyWith(filePath: vaultPath);
        }
        await _saveItem(item);

        if (!item.isPrivate && autoSaveVideos) {
          item = await _trySaveMediaAfterDownload(item);
        }

        unawaited(
          _notifications.showDownloadComplete(
            id: item.id.hashCode,
            title: item.title,
            type: item.isVideo ? 'Video' : 'Audio',
            downloadId: item.id,
          ),
        );
        notifyListeners();
      } catch (e) {
        final failedItem = item.copyWith(
          status: DownloadStatus.failed,
          progress: 0,
        );
        await _saveItem(failedItem);
        unawaited(
          _notifications.showDownloadFailed(
            id: item.id.hashCode,
            title: item.title,
            error: e.toString().replaceAll('Exception: ', ''),
          ),
        );
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
    _finishDownload(item.id);
    await _controlDownload(item: item, action: 'cancel');
  }

  Future<void> deleteDownload(DownloadItem item) async {
    _finishDownload(item.id);
    await _files.deleteFile(item.filePath);
    _privateMetadata.remove(item.id);
    await _store.delete(item.id);
    _downloads = _store.readDownloads();
    await _persistPrivateMetadata();
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
    if (_rejectIfBusy()) return;

    if (!Platform.isAndroid) {
      throw Exception(
        'Ringtones can only be set programmatically on Android devices.',
      );
    }

    final bool canWrite =
        await _channel.invokeMethod<bool>('canWriteSettings') ?? false;
    if (!canWrite) {
      await _channel.invokeMethod<void>('requestWriteSettingsPermission');
      throw Exception(
        'Permission required: Please enable "Allow modifying system settings" in Android Settings, then try again.',
      );
    }

    busy = true;
    setStatus('statusPreparingRingtone');
    notifyListeners();

    String? inputPath;
    try {
      final info = await _getEffectivePathAndFileName(item);
      inputPath = info['path']!;

      final root = await getApplicationDocumentsDirectory();
      final folder = Directory(
        p.join(root.path, 'Duck Downloader', 'Ringtones'),
      );
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
        setStatus('statusTrimmingAudio');
        notifyListeners();

        try {
          final trimmedTempPath = await _trimService
              .trimLocalFile(
                inputPath: inputPath,
                startSec: startTime,
                endSec: endTime,
                type: DownloadType.audio,
              )
              .timeout(const Duration(seconds: 4));
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

      setStatus('statusSettingRingtone');
      notifyListeners();

      final bool success =
          await _channel.invokeMethod<bool>('setRingtone', {
            'path': finalPath,
            'title': item.title,
          }) ??
          false;

      if (success) {
        setStatus('statusRingtoneSet');
      } else {
        throw Exception(
          'Could not register ringtone in Android system database.',
        );
      }
    } catch (e) {
      setStatus('statusGenericError', {'error': e.toString()});
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
    setStatus(enabled ? 'statusAutoSaveOn' : 'statusAutoSaveOff');
    notifyListeners();
  }

  /// Returns true once, the first time the main screen appears after the
  /// intro. Clearing it here rather than at the call site means a crash while
  /// the sheet is opening cannot make the offer reappear on every launch.
  bool consumePendingPremiumOffer() {
    if (!_store.readPendingPremiumOffer()) return false;
    _store.writePendingPremiumOffer(false);
    return true;
  }

  /// User-facing opt-out for anonymous crash reports.
  Future<void> toggleCrashReporting(bool enabled) async {
    crashReportingEnabled = enabled;
    await _store.writeCrashReportingEnabled(enabled);
    await CrashReportingService.instance.setEnabled(enabled);
    setStatus(
      enabled ? 'statusCrashReportsOn' : 'statusCrashReportsOff',
    );
    notifyListeners();
  }

  void toggleClipboardDetection(bool value) {
    enableClipboardDetection = value;
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
    unawaited(_store.writeLastDownloadType(type.name));
    quality = _firstQuality(media, type);
    notifyListeners();
  }

  void changeQuality(String value) {
    quality = value;
    if (selectedType == DownloadType.video) {
      unawaited(_store.writeLastVideoQuality(value));
    } else if (selectedType == DownloadType.audio) {
      unawaited(_store.writeLastAudioQuality(value));
    } else if (selectedType == DownloadType.image) {
      unawaited(_store.writeLastImageQuality(value));
    }
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
        setStatus('statusDownloading');
      } else if (action == 'resume') {
        setStatus('statusPausing');
      } else if (action == 'pause') {
        setStatus('statusDownloadPaused');
        flow = DuckFlow.downloading;
      } else {
        _cancelDownloadSubscription(item.id);
        await _store.delete(next.id);
        _downloads = _store.readDownloads();
        if (activeId == item.id) {
          activeId = null;
          flow = DuckFlow.idle;
          setStatus('statusTapDuck');
        }
      }
      _syncActiveFlow();
      return next;
    } catch (error) {
      flow = DuckFlow.error;
      if (_cleanError(error).contains('Download not found')) {
        setStatus('statusBackendOutdated');
      } else {
        _status = _errorStatus(error);
      }
      return null;
    } finally {
      controlPendingIds.remove(item.id);
      notifyListeners();
    }
  }

  void _watchDownload(String id, DownloadItem baseItem) {
    if (_disposed) return;
    _cancelDownloadSubscription(id);
    var terminalReached = false;
    _downloadSubscriptions[id] = _api
        .watchDownload(id)
        .listen(
          (update) async {
            if (_disposed || terminalReached) return;
            if (update.status == DownloadStatus.completed ||
                update.status == DownloadStatus.failed ||
                update.status == DownloadStatus.cancelled) {
              terminalReached = true;
            }
            var next = baseItem.copyWith(
              progress: update.progress,
              status: update.status == DownloadStatus.completed
                  ? DownloadStatus.processing
                  : update.status,
            );
            await _saveItem(next);

            if (update.status == DownloadStatus.completed) {
              _finishDownload(id);
              if (update.fileUrl == null) {
                next = next.copyWith(status: DownloadStatus.failed);
                await _saveItem(next);
                flow = DuckFlow.error;
                setStatus('statusNoFileUrl');
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
                  setStatus(
                    next.externalSaveError != null
                        ? 'statusCompleteSaveFailed'
                        : next.type == DownloadType.image
                        ? 'statusCompleteSavedPictures'
                        : next.isVideo && next.savedToGallery
                        ? 'statusCompleteSavedGallery'
                        : 'statusComplete',
                  );
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
              _finishDownload(id);
              final errText = update.error ?? '';
              final isLoginRequired = _isLoginRequiredError(errText);

              await _saveItem(next.copyWith(status: DownloadStatus.failed));
              flow = DuckFlow.error;
              status = _cleanError(
                errText.isNotEmpty ? errText : 'Download failed.',
              );

              if (isLoginRequired &&
                  !_justSignedIn &&
                  _requestLogin(baseItem.url)) {
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
              setStatus('statusDownloadPaused');
              flow = DuckFlow.downloading;
            }

            if (update.status == DownloadStatus.cancelled) {
              _finishDownload(id);
              await _store.delete(next.id);
              _downloads = _store.readDownloads();
              if (activeId == id) {
                activeId = null;
                flow = DuckFlow.idle;
                setStatus('statusTapDuck');
              }
            }
            _syncActiveFlow();
            notifyListeners();
          },
          onError: (Object error) {
            if (_disposed || terminalReached) return;
            terminalReached = true;
            _finishDownload(id);
            flow = DuckFlow.error;
            _status = _errorStatus(error);
            notifyListeners();
          },
          // The socket closing without ever reporting a terminal status.
          //
          // Nothing handled this, so the download kept its queue slot for the
          // rest of the session: three of these and the queue stopped starting
          // anything, with a row still reading "downloading" behind a
          // connection that was gone.
          onDone: () async {
            if (_disposed || terminalReached) return;
            _finishDownload(id);
            final current = _downloads
                .where((entry) => entry.id == id)
                .firstOrNull;
            if (current == null) return;
            final unfinished = current.status == DownloadStatus.queued ||
                current.status == DownloadStatus.downloading;
            if (!unfinished) return;
            try {
              await _saveItem(current.copyWith(status: DownloadStatus.failed));
            } catch (error, stackTrace) {
              reportError(error, stackTrace, reason: 'download-socket-closed');
            }
            flow = DuckFlow.error;
            setStatus('statusServerClosed');
            notifyListeners();
          },
        );
  }

  // ── Progress reporting ────────────────────────────────────────────────────

  /// Percent last published per download, so unchanged ticks cost nothing.
  final Map<String, int> _lastPublishedProgress = {};

  /// When each download last wrote its progress to disk.
  final Map<String, DateTime> _lastProgressPersist = {};

  /// How often an in-flight download checkpoints to storage.
  ///
  /// Only so a crash mid-download does not rewind the bar to zero. The value
  /// on screen comes from memory, so this has nothing to do with smoothness.
  static const _progressCheckpoint = Duration(seconds: 5);

  /// Publishes download progress without paying for a full save.
  ///
  /// Progress ticks arrive once per network chunk — hundreds to thousands per
  /// download. Routing each one through _saveItem meant two disk writes, a
  /// re-read and full JSON re-parse of every download in history, and a
  /// rebuild of the entire list, all before the next chunk landed. With a few
  /// hundred items in history that is the whole frame budget spent on
  /// bookkeeping, which is why the bar stuttered rather than moved.
  ///
  /// So: skip ticks that do not change the whole percent, update the item in
  /// memory, and let storage lag behind on a timer.
  Future<void> _publishProgress(
    DownloadItem item,
    int progress, {
    DownloadStatus status = DownloadStatus.downloading,
  }) async {
    final index = _downloads.indexWhere((entry) => entry.id == item.id);
    if (index < 0) return;

    final unchanged = _lastPublishedProgress[item.id] == progress &&
        _downloads[index].status == status;
    if (unchanged) return;
    _lastPublishedProgress[item.id] = progress;

    final updated = _downloads[index].copyWith(
      progress: progress,
      status: status,
    );
    _downloads[index] = updated;
    if (updated.isPrivate) _privateMetadata[item.id] = updated;
    _syncKeepAlive();
    notifyListeners();

    final lastWrite = _lastProgressPersist[item.id];
    if (lastWrite != null &&
        DateTime.now().difference(lastWrite) < _progressCheckpoint) {
      return;
    }
    _lastProgressPersist[item.id] = DateTime.now();
    try {
      await _store.upsert(updated);
    } catch (error) {
      // A failed checkpoint costs nothing the user can see — the download
      // keeps running and the final save is what actually matters.
      reportError(error, StackTrace.current, reason: 'progress-checkpoint');
    }
  }

  /// Clears the per-download progress bookkeeping once it is no longer live.
  void _forgetProgress(String id) {
    _lastPublishedProgress.remove(id);
    _lastProgressPersist.remove(id);
  }

  Future<void> _saveItem(DownloadItem item) async {
    // A late callback from a stream that outlived the controller. Its storage
    // is closed, so writing here throws inside a stream handler nobody is
    // listening to.
    if (_disposed) return;
    if (item.isPrivate && !VaultEncryptionService.isUnlocked) {
      throw StateError(
        'Unlock the Secure Vault before saving private content.',
      );
    }
    if (item.isPrivate) {
      _privateMetadata[item.id] = item;
      await _persistPrivateMetadata();
    } else {
      _privateMetadata.remove(item.id);
      await _persistPrivateMetadata();
    }
    await _store.upsert(item);
    // Once a download reaches a terminal state its throttling state is dead
    // weight — and keeping it would make a later retry of the same id skip
    // its first ticks as "unchanged".
    if (item.status != DownloadStatus.downloading &&
        item.status != DownloadStatus.processing) {
      _forgetProgress(item.id);
    }
    _downloads = _store.readDownloads();
    _mergePrivateMetadata();
    _syncActiveFlow();
    _syncKeepAlive();
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
    if (item.isPrivate && isVaultLocked) {
      setStatus('statusUnlockVaultFirst');
      notifyListeners();
      return;
    }
    externalSaveBusy = true;
    setStatus(
      type == DownloadType.video
          ? 'statusSavingGallery'
          : type == DownloadType.audio
          ? 'statusSavingAudio'
          : 'statusSavingImage',
    );
    notifyListeners();
    try {
      final next = type == DownloadType.video
          ? await _saveVideoItem(item)
          : type == DownloadType.audio
          ? await _saveAudioItem(item)
          : await _saveImageItem(item);
      setStatus(
        type == DownloadType.video
            ? 'statusSavedGallery'
            : type == DownloadType.audio
            ? 'statusSavedAudio'
            : 'statusSavedImage',
      );
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

  Future<Map<String, String>> _getEffectivePathAndFileName(
    DownloadItem item,
  ) async {
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
    return {'path': effectivePath, 'filename': fileName};
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
            throw Exception(
              'Storage permission is required to save images: $e',
            );
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

      final cleanTitle = item.title.replaceAll(
        RegExp(r'\.(jpg|jpeg|png|webp|gif)$', caseSensitive: false),
        '',
      );
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
      final cleanTitle = item.title.replaceAll(
        RegExp(r'\.(mp3|m4a)$', caseSensitive: false),
        '',
      );
      return '$cleanTitle.$ext';
    }

    String ext = 'mp4';
    if (!item.isPrivate) {
      final pathExt = item.filePath?.split('.').last ?? 'mp4';
      if (pathExt != 'enc') ext = pathExt;
    }
    final cleanTitle = item.title.replaceAll(
      RegExp(r'\.mp4$', caseSensitive: false),
      '',
    );
    return '$cleanTitle.$ext';
  }

  Future<void> markAudioBackgroundReady() async {
    if (audioBackgroundReady) return;
    audioBackgroundReady = true;
    if (_audioBackgroundCompleter != null &&
        !_audioBackgroundCompleter!.isCompleted) {
      _audioBackgroundCompleter!.complete();
    }
    notifyListeners();
  }

  Future<void> _ensureAudioBackgroundReady() async {
    if (audioBackgroundReady) return;
    _audioBackgroundCompleter ??= Completer<void>();
    try {
      await _audioBackgroundCompleter!.future.timeout(
        const Duration(seconds: 5),
      );
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
      if (!advanceQueue) _buildAudioQueue(item);
      await audioPlayer.stop();
      await _clearActiveDecryptedAudio();
      final playablePath = await _getEffectiveInputPath(item);
      if (item.isPrivate) _activeDecryptedAudioPath = playablePath;
      playingItem = item;
      playerItem = item;
      notifyListeners();
      try {
        await _ensureAudioBackgroundReady();
        if (audioBackgroundReady) {
          await audioPlayer.setAudioSource(
            AudioSource.file(
              playablePath,
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
          await audioPlayer.setFilePath(playablePath);
        }
        await _applyPlayerLoopMode();
        await audioPlayer.play();
      } catch (error) {
        playingItem = null;
        setStatus('statusPlayFailed', {'error': '$error'});
        await _clearActiveDecryptedAudio();
        notifyListeners();
      }
    } else {
      await audioPlayer.stop();
      await _clearActiveDecryptedAudio();
      playingItem = null;
      unawaited(openPlayer(item));
    }
  }

  Future<void> _clearActiveDecryptedAudio() async {
    final path = _activeDecryptedAudioPath;
    _activeDecryptedAudioPath = null;
    if (path == null) return;
    try {
      await File(path).delete();
    } catch (_) {}
  }

  void _buildAudioQueue(DownloadItem item, {bool forceReshuffle = false}) {
    final source = _audioQueueSource ?? audios;
    final sourceKey = source.map((entry) => entry.id).join('|');
    final sourceChanged = sourceKey != _lastQueueSourceKey;
    _lastQueueSourceKey = sourceKey;

    _audioQueue = source
        .where((entry) => entry.filePath != null && entry.isAudio)
        .toList();
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
    _videoQueue = source
        .where((entry) => entry.filePath != null && entry.isVideo)
        .toList();
    _videoQueueIndex = _videoQueue.indexWhere((entry) => entry.id == item.id);
    if (_videoQueueIndex < 0) {
      _videoQueue = [item];
      _videoQueueIndex = 0;
    }
  }

  void playNextVideo() {
    if (!hasNextVideo) return;
    _videoQueueIndex++;
    unawaited(
      openPlayer(
        _videoQueue[_videoQueueIndex],
        galleryItems: playerGalleryItems,
        queueItems: _audioQueueSource,
      ),
    );
  }

  void playPreviousVideo() {
    if (!hasPreviousVideo) return;
    _videoQueueIndex--;
    unawaited(
      openPlayer(
        _videoQueue[_videoQueueIndex],
        galleryItems: playerGalleryItems,
        queueItems: _audioQueueSource,
      ),
    );
  }

  Future<void> toggleShuffle() async {
    shuffleEnabled = !shuffleEnabled;
    if (playingItem != null) {
      _buildAudioQueue(playingItem!, forceReshuffle: shuffleEnabled);
    }
    unawaited(_store.writeShuffleEnabled(shuffleEnabled));
    notifyListeners();
  }

  Future<void> toggleLoopMode() async {
    _loopMode = switch (_loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await _applyPlayerLoopMode();
    unawaited(_store.writePlaybackLoopMode(_loopMode.name));
    notifyListeners();
  }

  /// Tells the player how to loop — which is not the same question this class
  /// is answering.
  ///
  /// `audioPlayer` is driving one file at a time, not a playlist, so
  /// `LoopMode.all` there means "repeat this file". Handing `_loopMode`
  /// straight over made "repeat all" behave exactly like "repeat one": the
  /// player looped the track itself, `ProcessingState.completed` never fired,
  /// and the listener that calls [playNext] never ran.
  ///
  /// Only repeat-one maps onto the player. Moving through the queue is this
  /// class's job, and it needs the player to report the end of a track to do
  /// it.
  static LoopMode _readStoredLoopMode(String? name) {
    return switch (name) {
      'all' => LoopMode.all,
      'one' => LoopMode.one,
      _ => LoopMode.off,
    };
  }

  Future<void> _applyPlayerLoopMode() async {
    await audioPlayer.setLoopMode(
      _loopMode == LoopMode.one ? LoopMode.one : LoopMode.off,
    );
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

  Future<void> _initializePlatformServices() async {
    await _requestPermissionsSafely();
    await loadCookiesStatus();
    // Deliberately no folder scan here. It used to run on every cold start,
    // and most sessions never open the browser at all — the user pastes a link
    // and leaves. The browser now asks for it when it opens.
  }

  Future<void> _requestPermissionsSafely() async {
    try {
      await _permissions.requestAllRequiredPermissions();
    } catch (error, stackTrace) {
      reportError(error, stackTrace, reason: 'permission-request');
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
    unawaited(audioPlayer.stop());
    unawaited(_clearActiveDecryptedAudio());
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
    try {
      final info = await _getEffectivePathAndFileName(item);
      final path = info['path'];
      if (path == null) return;

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

      // Start the media session while the app is still in the foreground.
      //
      // This is the whole reason background playback was failing. Since
      // Android 12 an app in the background may not *start* a foreground
      // service, and `just_audio_background` needs one. Locking the screen
      // put the app in the background first, so the play() that followed threw
      // ForegroundServiceStartNotAllowedException and the audio never came.
      //
      // Playing for an instant here starts that service while it is still
      // legal to, and pausing immediately leaves it alive and idle — the
      // notification is ongoing, so the service is not torn down. By the time
      // the screen locks there is nothing left to start: the handoff only has
      // to seek and unmute, which is why it is instant.
      await audioPlayer.play();
      await audioPlayer.pause();
      await audioPlayer.seek(Duration.zero);

      _backgroundVideoPreloaded = true;
      playingItem = item;
      backgroundAudioError = null;
      debugPrint('BG AUDIO: preloaded and session started for ${item.title}');
    } catch (e) {
      _backgroundVideoPreloaded = false;
      backgroundAudioError = 'preload failed: $e';
      debugPrint('BG AUDIO: preload failed — $e');
    }
  }

  bool _backgroundVideoPreloaded = false;

  /// Ensures background audio is loaded and activates playback.
  Future<void> ensureAndActivateBackgroundAudio(
    DownloadItem item,
    Duration position,
  ) async {
    if (!_backgroundVideoPreloaded) {
      await preloadBackgroundAudio(item);
    }
    await activateBackgroundAudio(position);
  }

  /// Activates the pre-loaded background audio player by seeking to the
  /// video's current position, unmuting, and starting playback.
  /// Because the audio source is already loaded, this is nearly instant.
  /// Last reason background audio failed to start, for diagnostics.
  String? backgroundAudioError;

  Future<void> activateBackgroundAudio(Duration position) async {
    if (!_backgroundVideoPreloaded) {
      backgroundAudioError = 'audio source was never preloaded';
      debugPrint('BG AUDIO: $backgroundAudioError');
      return;
    }
    if (_backgroundVideoActive) return;
    try {
      _backgroundVideoActive = true;
      await audioPlayer.seek(position);
      await audioPlayer.setVolume(1.0); // unmute — instant!
      await audioPlayer.play();
      backgroundAudioError = null;
      debugPrint('BG AUDIO: playing from $position');
      notifyListeners();
    } catch (e) {
      _backgroundVideoActive = false;
      backgroundAudioError = e.toString();
      // Should no longer be reachable for the Android 12+ foreground-service
      // restriction — preloadBackgroundAudio starts that service while the app
      // is still on screen. Kept because a decode error or a file that moved
      // out from under us can still land here, and silence with no explanation
      // is the worst outcome.
      debugPrint('BG AUDIO: activation failed — $e');
    }
  }

  /// Deactivates background audio when the video player resumes.
  /// Mutes and pauses instead of stopping, so the source stays loaded
  /// for the next screen lock (no re-loading needed).
  Future<void> deactivateBackgroundAudio() async {
    if (!_backgroundVideoActive) return;
    _backgroundVideoActive = false;
    await audioPlayer.setVolume(0.0); // mute — instant
    await audioPlayer.pause(); // pause, don't stop (keeps source loaded)
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
        setStatus('statusTapDuck');
      }
    }
    if (active.isNotEmpty &&
        (flow == DuckFlow.idle || flow == DuckFlow.success)) {
      activeId ??= active.first.id;
      flow = DuckFlow.downloading;
      setStatus('statusDownloading');
    }
  }

  DownloadType _selectDefaultDownloadType(
    MediaMetadata media,
    String cleanUrl,
  ) {
    if (_isImageMetadata(media) || _looksLikeImageUrl(cleanUrl)) {
      return DownloadType.image;
    }
    final savedType = _store.readLastDownloadType();
    if (savedType == 'audio') {
      return DownloadType.audio;
    } else if (savedType == 'image') {
      return DownloadType.image;
    }
    return DownloadType.video;
  }

  String _firstQuality(MediaMetadata media, DownloadType type) {
    String? savedPreference;
    if (type == DownloadType.video) {
      savedPreference = _store.readLastVideoQuality();
    } else if (type == DownloadType.audio) {
      savedPreference = _store.readLastAudioQuality();
    } else if (type == DownloadType.image) {
      savedPreference = _store.readLastImageQuality();
    }

    if (type == DownloadType.image) {
      final formats = media.qualities;
      if (formats.isEmpty) return 'Original Image';
      if (savedPreference != null) {
        final match = formats.firstWhere(
          (f) =>
              f.label == savedPreference ||
              f.label.toLowerCase() == savedPreference!.toLowerCase(),
          orElse: () => formats.first,
        );
        return match.label;
      }
      return formats.first.label;
    }

    final formats = type == DownloadType.video
        ? media.qualities
        : media.audioFormats;
    if (formats.isEmpty) {
      return type == DownloadType.audio ? 'Best audio' : 'Best';
    }

    if (savedPreference != null) {
      final exactMatch = formats.firstWhere(
        (f) =>
            f.label == savedPreference ||
            f.label.toLowerCase() == savedPreference!.toLowerCase(),
        orElse: () => const FormatInfo(id: '', label: ''),
      );
      if (exactMatch.label.isNotEmpty) {
        return exactMatch.label;
      }
      final partialMatch = formats.firstWhere(
        (f) =>
            f.label.toLowerCase().contains(savedPreference!.toLowerCase()) ||
            savedPreference.toLowerCase().contains(f.label.toLowerCase()),
        orElse: () => formats.first,
      );
      return partialMatch.label;
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

  /// Whether signing in is a plausible fix for this failure.
  ///
  /// The host list this used to carry was a second copy of the platform table
  /// and had already drifted from it — Threads and Udemy were missing from the
  /// button that opened the browser, so they opened as a generic "Social" and
  /// took the wrong path from there. `profileForUrl` is the only list now.
  bool _shouldAskToSignIn(String url, Object error) {
    // One attempt. Fail, sign in, fail again is an error to report, not a
    // reason to ask for another sign-in.
    if (_justSignedIn) return false;

    final profile = profileForUrl(url);
    if (profile == null) return _isLoginRequiredError(error.toString());

    if (profile.platform == SocialPlatform.youtube) {
      // YouTube fails for reasons a sign-in cannot fix far more often than the
      // others, so it has to actually look like an access problem — and the
      // phrases have to come from YouTube, not from a sentence this app wrote
      // to describe a failure it did not understand.
      final message = error.toString().toLowerCase();
      return _isLoginRequiredError(message) ||
          message.contains('unplayable') ||
          message.contains('age-restricted') ||
          message.contains('age restricted') ||
          message.contains('forbidden');
    }
    return true;
  }

  /// True when signing in is the way out of what is currently on screen.
  ///
  /// Two things had to be added to this. It used to search the status text for
  /// the words "in-app browser", so the only way out of an error was tied to
  /// one English phrasing. And it did not include the status the app sets when
  /// it asks for a sign-in, so backing out of the sign-in screen left the user
  /// with no button at all — the link had to be pasted again from scratch.
  ///
  /// The last clause is the load-bearing one: a site nothing here can sign
  /// into must not be offered a sign-in button.
  bool get needsBrowserLogin =>
      (statusMessage.isKey('errorLoginRequired') ||
          statusMessage.isKey('errorExtractFailed') ||
          statusMessage.isKey('statusSignInRequired')) &&
      profileForUrl(_loginRequest?.retryUrl ?? lastAttemptedUrl ?? '') != null;

  /// The key this error maps onto, or null when only the raw text is left.
  ///
  /// These are the sentences the user actually reads when something fails, and
  /// they were the largest block of untranslated text in the app: an Arabic
  /// user hit a private Instagram post and got an English paragraph.
  /// Real network failures, as the platform actually words them.
  ///
  /// Deliberately specific. The list this replaces ended with
  /// `lower.contains('http')`, and every Dio failure prints the request URL in
  /// its message — so a 403 from googlevideo, a missing format, an ffmpeg
  /// error carrying a log line, all arrived at the user as "Connection
  /// problem. Check your internet and try again." while their internet was
  /// fine. The real reason never reached the screen, and never reached a bug
  /// report either.
  static const _networkSignals = <String>[
    'socketexception',
    'handshakeexception',
    'timeoutexception',
    'connectiontimeout',
    'receivetimeout',
    'sendtimeout',
    'connectionerror',
    'connection timed out',
    'connection refused',
    'connection reset',
    'connection closed',
    'connection terminated',
    'failed host lookup',
    'network is unreachable',
    'no address associated',
    'software caused connection abort',
    'os error',
  ];

  /// The HTTP status a failure is reporting, when it names one.
  ///
  /// Dio spells this out in prose — "status code of 403" — so the number is
  /// recoverable, and a refusal by the server is a different problem from the
  /// phone having no signal.
  static int? _statusCodeIn(String lower) {
    final match = RegExp(
      r'status code (?:of )?(\d{3})',
    ).firstMatch(lower);
    if (match != null) return int.tryParse(match.group(1)!);
    final http = RegExp(r'http (?:error )?(\d{3})').firstMatch(lower);
    return http == null ? null : int.tryParse(http.group(1)!);
  }

  String? _errorKeyFor(String lower) {
    if (lower.contains('blocked_adult_content')) return 'errorAdultBlocked';
    if (lower.contains('adult_check_unavailable')) {
      return 'statusAdultCheckUnavailable';
    }

    // 1. Sign-in walls and bot checks.
    //
    // `bot` is matched as a whole word. As a bare substring it also matched
    // "robot", "bots" and anything else that happened to contain it.
    if (lower.contains('sign in') ||
        RegExp(r'\bbots?\b').hasMatch(lower) ||
        lower.contains('captcha') ||
        lower.contains('confirm you are not')) {
      return 'errorYouTubeBlocking';
    }

    // 2. The server refused us rather than the network failing. Checked before
    //    the network bucket, because these carry a URL and used to be filed as
    //    "check your internet".
    final status = _statusCodeIn(lower);
    if (status == 403 || status == 429) return 'errorYouTubeBlocking';
    if (status == 401) return 'errorLoginRequired';
    if (status == 404 || status == 410) return 'errorUnsupportedLink';

    // 3. Extraction failures.
    if (lower.contains('cannot parse data') ||
        lower.contains('extractor') ||
        lower.contains('unable to extract')) {
      return 'errorExtractFailed';
    }

    // 4. Private or login-gated content.
    if (lower.contains('login') ||
        lower.contains('private') ||
        lower.contains('cookies')) {
      return 'errorLoginRequired';
    }

    // 5. Unsupported URLs.
    if (lower.contains('unsupported url') || lower.contains('unsupported')) {
      return 'errorUnsupportedLink';
    }

    // 6. And only now, an actual network problem.
    for (final signal in _networkSignals) {
      if (lower.contains(signal)) return 'errorConnection';
    }
    return null;
  }

  /// An error as something the status line can translate.
  ///
  /// Anything that does not match a known category stays as the backend's own
  /// text: one English sentence from the server beats showing the user nothing.
  DuckStatus _errorStatus(Object error) {
    final cleaned = _rawError(error);
    final key = _errorKeyFor(cleaned.toLowerCase());
    if (key != null) return DuckStatus.key(key);
    if (cleaned.isEmpty || cleaned == 'null') {
      return const DuckStatus.key('errorDownloadFailed');
    }
    return DuckStatus.literal(cleaned);
  }

  String _rawError(Object error) {
    return error
        .toString()
        .replaceFirst('Exception: ', '')
        .replaceFirst('WebSocketChannelException: ', '')
        .trim();
  }

  /// The English form, for the places that need a plain string — a thrown
  /// exception message, or a log line.
  String _cleanError(Object error) => _errorStatus(error).english;

  Future<_AdultVerdict> _isAdultUrl(String url) async {
    try {
      final cleanUrl = url.trim();
      final uri = Uri.parse(cleanUrl);
      final host = uri.host;
      if (host.isEmpty) return _AdultVerdict.allowed;

      // Reddit needs the post itself checked, not the domain: reddit.com is
      // mainstream, but individual posts and whole subreddits are marked adult.
      // `over_18` is Reddit's own flag, so it is authoritative where a
      // hostname keyword or DNS filter would wave the link straight through.
      if (RedditService.isRedditUrl(cleanUrl)) {
        final post = await _reddit.fetchPost(cleanUrl);
        if (post != null) {
          return post.isNsfw ? _AdultVerdict.blocked : _AdultVerdict.allowed;
        }
        // The flag could not be read. Everywhere else a failed check is a
        // missing signal among several; here it is *the* signal, and letting
        // the link through means the one authoritative source said nothing and
        // nobody noticed. Refuse and say so, rather than guess.
        return _AdultVerdict.unverified;
      }

      // 0. Check Twitter / X adult sensitive media
      final lowerUrl = cleanUrl.toLowerCase();
      if (lowerUrl.contains('twitter.com') ||
          lowerUrl.contains('x.com') ||
          lowerUrl.contains('t.co')) {
        final tweetIdMatch = RegExp(r'status/(\d+)').firstMatch(cleanUrl);
        if (tweetIdMatch != null) {
          final tweetId = tweetIdMatch.group(1);
          // Closed in the finally below. Three of these were opened per check
          // and none was ever closed, so every link the user pasted leaked a
          // connection pool that stayed alive for the rest of the session.
          final client = HttpClient();
          try {
            client.connectionTimeout = const Duration(seconds: 4);

            // Source 1: Twitter Syndication API with Chrome User-Agent
            final request1 = await client.getUrl(
              Uri.parse(
                'https://cdn.syndication.twimg.com/tweet-result?id=$tweetId',
              ),
            );
            request1.headers.set(
              'User-Agent',
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
            );
            request1.headers.set('Accept', 'application/json');
            final response1 = await request1.close();
            if (response1.statusCode == 200) {
              final bodyText = await response1.transform(utf8.decoder).join();
              final data = jsonDecode(bodyText);
              if (data is Map) {
                final bool possiblySensitive =
                    data['possibly_sensitive'] == true;
                final bool sensitiveMedia = data['sensitive_media'] == true;
                final text = (data['text'] ?? '').toString().toLowerCase();
                final hasNsfwTag =
                    text.contains('#nsfw') ||
                    text.contains('#18plus') ||
                    text.contains('#18+') ||
                    text.contains('#adult') ||
                    text.contains('#porn') ||
                    text.contains('#hentai') ||
                    text.contains('#erotic') ||
                    text.contains('#nude');
                if (possiblySensitive || sensitiveMedia || hasNsfwTag) {
                  debugPrint(
                    '⚡ Duck Downloader: Twitter/X NSFW sensitive media detected for Tweet ID: $tweetId (Syndication)',
                  );
                  return _AdultVerdict.blocked;
                }
              }
            }

            // Source 2: FxTwitter API fallback
            final request2 = await client.getUrl(
              Uri.parse('https://api.fxtwitter.com/status/$tweetId'),
            );
            request2.headers.set(
              'User-Agent',
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
            );
            request2.headers.set('Accept', 'application/json');
            final response2 = await request2.close();
            if (response2.statusCode == 200) {
              final bodyText = await response2.transform(utf8.decoder).join();
              final data = jsonDecode(bodyText);
              if (data is Map && data['tweet'] is Map) {
                final tweet = data['tweet'] as Map;
                final bool sensitive = tweet['possibly_sensitive'] == true;
                if (sensitive) {
                  debugPrint(
                    '⚡ Duck Downloader: Twitter/X NSFW sensitive media detected for Tweet ID: $tweetId (FxTwitter)',
                  );
                  return _AdultVerdict.blocked;
                }
              }
            }
          } catch (e) {
            debugPrint('Twitter NSFW check error: $e');
          } finally {
            client.close(force: true);
          }
        }
      }

      // 1. Quick local keyword check for instant block (covering porn, hentai, and AI content)
      final lowerHost = host.toLowerCase();
      final localKeywords = [
        'porn',
        'xxx',
        'sex',
        'nude',
        'adult',
        'camgirl',
        'livecam',
        'hentai',
        'xvideo',
        'pornhub',
        'xnxx',
        'xhamster',
        'redtube',
        'youporn',
        'chaturbate',
        'rule34',
        'onlyfans',
        'stripchat',
        'bongacams',
        'camsoda',
        'adultfriendfinder',
        'cam4',
        'imlive',
        'livejasmin',
        'doujin',
        'nhentai',
        'gelbooru',
        'danbooru',
        'e621',
        'sankakucomplex',
        'yande.re',
        'rule34.xxx',
        'e-hentai',
        'luscious',
        'spankbang',
        'eporner',
        'hqporn',
        'motherless',
        'heavyr',
        'tube8',
        'pornai',
        'aiporn',
        'nudify',
        'undressai',
        'pornpen',
        'soulgen',
        'candyai',
        'dreamgf',
        'nsfwai',
        'spicychat',
        'janitorai',
      ];
      for (final kw in localKeywords) {
        if (lowerHost.contains(kw)) return _AdultVerdict.blocked;
      }

      // 2. Query both Cloudflare Families and AdGuard Family DNS in parallel (DoH)
      final results = await Future.wait([
        _queryCloudflareFamilies(host),
        _queryAdGuardFamily(host),
      ]).timeout(const Duration(seconds: 4), onTimeout: () => [false, false]);

      return results[0] || results[1]
          ? _AdultVerdict.blocked
          : _AdultVerdict.allowed;
    } catch (_) {
      // A DNS lookup or a syndication API being unreachable is one missing
      // signal out of several, on a link that is usually ordinary. Blocking
      // every download whenever the network hiccups is its own failure.
    }
    return _AdultVerdict.allowed;
  }

  Future<bool> _queryCloudflareFamilies(String host) async {
    final client = HttpClient();
    try {
      client.connectionTimeout = const Duration(seconds: 3);
      final request = await client.getUrl(
        Uri.parse(
          'https://family.cloudflare-dns.com/dns-query?name=${Uri.encodeComponent(host)}&type=A',
        ),
      );
      request.headers.set('Accept', 'application/dns-json');
      final response = await request.close();
      if (response.statusCode == 200) {
        final bodyText = await response.transform(utf8.decoder).join();
        final data = jsonDecode(bodyText);
        if (data is Map) {
          final answers = data['Answer'];
          if (answers is List) {
            for (final answer in answers) {
              if (answer is Map &&
                  (answer['data'] == '0.0.0.0' || answer['data'] == '::')) {
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
    } catch (_) {
      // A filter being unreachable is not evidence about the link.
    } finally {
      client.close(force: true);
    }
    return false;
  }

  Future<bool> _queryAdGuardFamily(String host) async {
    final client = HttpClient();
    try {
      client.connectionTimeout = const Duration(seconds: 3);
      final request = await client.getUrl(
        Uri.parse(
          'https://dns-family.adguard.com/dns-query?name=${Uri.encodeComponent(host)}&type=A',
        ),
      );
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
                if (ip == '0.0.0.0' ||
                    ip == '127.0.0.1' ||
                    ip.startsWith('94.140.')) {
                  return true;
                }
              }
            }
          }
        }
      }
    } catch (_) {
      // A filter being unreachable is not evidence about the link.
    } finally {
      client.close(force: true);
    }
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Locking the vault on the way out is what keeps private media off the
      // recents thumbnail — that part stays.
      //
      // `inactive` used to be in this list and should never have been. It does
      // not mean "the app is leaving": it fires on a rotation, on the
      // notification shade being pulled down, on any system dialog, and on the
      // way into and out of Picture-in-Picture. Opening a vault video rotates
      // the screen, so the vault locked itself while the user was still in it,
      // and going back showed an empty list. `paused` is the state that
      // actually precedes the recents snapshot, so the protection is intact.
      lockVault();

      // Tearing the player down as well used to happen here, which made
      // Picture-in-Picture and background audio impossible: closePlayer()
      // clears playerItem, the overlay leaves the tree, and its dispose()
      // releases the video controller — all in the same frame the platform is
      // trying to hand the video to a PiP window. `inactive` also fires on a
      // simple rotation, so turning the phone sideways closed the video too.
      //
      // The player now decides for itself what backgrounding means (see
      // DuckPlayerOverlay.didChangeAppLifecycleState), and only vault media
      // still has to disappear, because the vault above just locked.
      if (playerItem?.isPrivate == true) {
        closePlayer();
      }
    }
    if (state == AppLifecycleState.resumed) {
      _checkClipboardOnResume();
      unawaited(_drainShareInbox());
    }
  }

  /// Silently drops notifications once the controller is gone.
  ///
  /// Downloads outlive the widget that started them by design — a queue, a
  /// socket and several awaits — so a job can land after dispose. The base
  /// class asserts on that, turning a harmless late callback into a crash.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingDownloads.clear();
    _runningDownloads.clear();
    _vaultIdleTimer?.cancel();
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
    _reddit.dispose();
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
            _notifications.showClipboardDetected(id: url.hashCode, url: url),
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

    if (_rejectIfBusy()) return;
    busy = true;
    flow = DuckFlow.extracting;
    setStatus('statusCheckingLink');
    _resetForNewExtraction();
    notifyListeners();

    try {
      await _extractUrlOrBatch(url);
    } catch (error) {
      flow = DuckFlow.error;
      _status = _errorStatus(error);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> extractCustomUrl(String url) async {
    setTab(DuckTab.home);
    if (_rejectIfBusy()) return;
    busy = true;
    flow = DuckFlow.extracting;
    setStatus('statusCheckingLink');
    _resetForNewExtraction();
    notifyListeners();

    try {
      final media = await _api.extract(url);
      metadata = media;
      if (_isImageMetadata(media) || _looksLikeImageUrl(url)) {
        selectedType = DownloadType.image;
        quality = _firstQuality(media, DownloadType.image);
        flow = DuckFlow.ready;
        setStatus('statusTapDownloadForImage');
      } else {
        selectedType = _selectDefaultDownloadType(media, url);
        quality = _firstQuality(media, selectedType);
        flow = DuckFlow.ready;
        setStatus(
          selectedType == DownloadType.audio
              ? 'statusChooseAudioFormat'
              : 'statusChooseVideoOrAudio',
        );
      }
    } catch (error) {
      flow = DuckFlow.error;
      _status = _errorStatus(error);
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
      await _enqueueDownload(
        placeholder: DownloadItem(
          id: _newLocalDownloadId(),
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
        ),
        begin: () => _api.startDownload(
          url: media.url,
          type: type,
          quality: quality,
          removeMusic: removeMusic,
          premiumNoWatermark: true,
        ),
      );
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
        debugPrint(
          'DEBUG BATCH: url=$url title=${batchItem?.title} isVideo=$isVideo forceHybrid=$forceHybrid itemType=$itemType',
        );
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
        // Instagram carousel items are direct CDN files. Same reasoning as
        // the single case: the phone can fetch them, and Meta answers it.
        if (_isDirectMetaMedia(url)) {
          await _startMetaBatchItem(
            url: url,
            title: title,
            item: batchItem,
            type: itemType,
          );
          started++;
          continue;
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

        if (_looksLikeImageUrl(url) ||
            itemType == DownloadType.image ||
            (itemType == DownloadType.video && isVideo)) {
          mediaUrl = url;
          thumbnail = batchItem?.thumbnail ?? url;
          platform = batchPlatform ?? 'Public source';
        } else {
          final media = await _api.extract(url);
          mediaUrl = media.url;
          thumbnail = media.thumbnail;
          platform = media.platform;
        }

        final requestedQuality =
            itemType == DownloadType.video ? 'Best' : quality;
        final stripAudio = removeMusic;
        await _enqueueDownload(
          placeholder: DownloadItem(
            id: _newLocalDownloadId(),
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
          ),
          begin: () => _api.startDownload(
            url: mediaUrl,
            type: itemType,
            quality: requestedQuality,
            removeMusic: stripAudio,
            premiumNoWatermark: true,
          ),
        );
        started++;
      } catch (error) {
        failed++;
      }
    }

    // "Queued", not "Started": with a concurrency cap only the first
    // [maxConcurrentDownloads] of these are actually running right now, and
    // saying otherwise is how a progress bar that has not moved looks broken.
    //
    // A key per kind rather than one with a `{noun}` slot: English pluralises
    // by adding an "s" to a noun the sentence can borrow, and Arabic does not
    // work that way at all.
    final images = type == DownloadType.image;
    if (started > 0 && failed > 0) {
      setStatus(
        images ? 'statusQueuedImagesPartial' : 'statusQueuedDownloadsPartial',
        {'count': '$started', 'failed': '$failed'},
      );
    } else if (started > 0) {
      setStatus(
        images ? 'statusQueuedImages' : 'statusQueuedDownloads',
        {'count': '$started'},
      );
    } else if (failed > 0) {
      setStatus(
        images ? 'statusQueueFailedImages' : 'statusQueueFailedDownloads',
        {'failed': '$failed'},
      );
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
    if (_rejectIfBusy()) return;
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
    setStatus('statusTrimmingFile');
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
      setStatus('statusTrimComplete');
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
    _metaPost = null;
    flow = DuckFlow.idle;
    setStatus('statusTapDuck');
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

  /// Forgets one platform's saved session.
  ///
  /// Replaces `updateCookies`/`clearCookies`, which pushed whatever cookies
  /// the browser had harvested to a single file on the server and to the
  /// on-device YouTube extractor at the same time. Signing into Instagram
  /// therefore erased the YouTube session, and on a shared server it handed
  /// one user's login to the next person who downloaded anything.
  Future<void> signOutOf(SocialPlatform platform) async {
    await _sessions.clear(platform);
    await _syncSessionsToNative();
    if (platform == SocialPlatform.youtube) {
      _ytExplode.updateCookies(null);
    }
    setStatus('accountsCleared');
    notifyListeners();
  }

  Future<void> signOutOfEverything() async {
    await _sessions.clearAll();
    await _syncSessionsToNative();
    _ytExplode.updateCookies(null);
    setStatus('accountsCleared');
    notifyListeners();
  }

  DateTime? _lastBackPressTime;

  bool handleDoubleBackToExit() {
    final now = DateTime.now();
    if (_lastBackPressTime == null ||
        now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
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

    // A share arriving while the app is already open.
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (value) {
        if (value.isNotEmpty) {
          _handleSharedText(value.first.path);
        }
      },
      onError: (err) {
        debugPrint("Sharing intent stream error: $err");
      },
    );

    // A share that started the app from cold.
    ReceiveSharingIntent.instance.getInitialMedia().then((value) {
      if (value.isNotEmpty) {
        _handleSharedText(value.first.path);
      }
      // Without this the plugin keeps handing back the same link on every
      // later cold start, so a video downloaded last week reappears as a fresh
      // share sheet the next time the app is opened from the launcher.
      ReceiveSharingIntent.instance.reset();
    });

  }

  String? sharedQuickDownloadUrl;
  MediaMetadata? _quickShareMetadata;
  bool isQuickShareMode = false;
  bool isQuickShareExtracting = false;
  List<FormatInfo> quickShareVideoQualities = [];
  List<FormatInfo> quickShareAudioQualities = [];

  void dismissQuickShare() {
    // Bumping the generation makes any extraction still in flight a no-op, so
    // a late result cannot reopen a sheet the user just closed.
    _quickShareGeneration++;
    sharedQuickDownloadUrl = null;
    isQuickShareMode = false;
    isQuickShareExtracting = false;
    quickShareError = null;
    quickShareVideoQualities.clear();
    quickShareAudioQualities.clear();
    _quickShareMetadata = null;
    notifyListeners();
  }

  Future<void> acceptQuickShareDownload(DownloadType type) async {
    final url = sharedQuickDownloadUrl;
    sharedQuickDownloadUrl = null;
    isQuickShareMode = false;
    showAdOnOpen = true; // Trigger ad on next app open
    selectedType = type;
    notifyListeners();
    if (url != null) {
      unawaited(autoExtractAndDownload(url));
    }
  }

  Future<void> acceptQuickShareDownloadWithFormat(
    FormatInfo format,
    DownloadType type,
  ) async {
    final url = sharedQuickDownloadUrl;
    sharedQuickDownloadUrl = null;
    isQuickShareMode = false;
    showAdOnOpen = true; // Trigger ad on next app open
    selectedType = type;
    quality = format.label;
    notifyListeners();
    if (url != null) {
      if (YouTubeExplodeService.isYouTubeUrl(url)) {
        unawaited(
          _startYouTubeExplodeBatchDownload(
            url: url,
            title: '',
            thumbnail: null,
            type: type,
            preferredFormat: format,
          ),
        );
      } else {
        metadata = _quickShareMetadata;
        if (metadata == null) {
          metadata = await _api.extract(url);
        }
        unawaited(startDownload());
      }
    }
  }

  /// Which share the sheet is currently showing.
  ///
  /// Extraction is slow and shares arrive whenever the user taps. Share link A,
  /// then B a second later, and A's result used to land last and overwrite B's
  /// quality list — leaving the sheet showing B's URL above A's formats, so
  /// tapping "1080p" downloaded B at a resolution it may not even have. Every
  /// result now checks it is still the current one before it is allowed to
  /// touch any state.
  int _quickShareGeneration = 0;

  /// What went wrong extracting the shared link, if anything.
  String? quickShareError;

  Future<void> _handleSharedText(String text) async {
    final url = RegExp(r'(https?://[^\s]+)').firstMatch(text)?.group(0);
    if (url == null) return;

    final generation = ++_quickShareGeneration;
    sharedQuickDownloadUrl = url;
    isQuickShareMode = true;
    isQuickShareExtracting = true;
    quickShareError = null;
    quickShareVideoQualities = [];
    quickShareAudioQualities = [];
    notifyListeners();

    try {
      final meta = YouTubeExplodeService.isYouTubeUrl(url)
          ? await _ytExplode.extractMetadata(url)
          : await _api.extract(url);
      if (generation != _quickShareGeneration) return;
      if (meta != null) {
        _quickShareMetadata = meta;
        quickShareVideoQualities = meta.qualities;
        quickShareAudioQualities = meta.audioFormats;
      }
    } catch (error, stackTrace) {
      if (generation != _quickShareGeneration) return;
      reportError(error, stackTrace, reason: 'quick-share-metadata');
      // The sheet used to fail silently: spinner stops, no qualities, no
      // reason. The default buttons still work, so say what happened and
      // leave them.
      quickShareError = _cleanError(error);
    } finally {
      if (generation == _quickShareGeneration) {
        isQuickShareExtracting = false;
        notifyListeners();
      }
    }
  }

  Future<void> autoExtractAndDownload(String url) async {
    if (_rejectIfBusy()) return;
    busy = true;
    lastDownloadedItem = null;
    flow = DuckFlow.extracting;
    setStatus('statusAutoDownloading');
    notifyListeners();

    try {
      final cleanUrl = url.trim();
      final verdict = await _isAdultUrl(cleanUrl);
      if (verdict == _AdultVerdict.blocked) {
        isAdultContentBlocked = true;
        notifyListeners();
        throw Exception('BLOCKED_ADULT_CONTENT');
      }
      if (verdict == _AdultVerdict.unverified) {
        throw Exception('ADULT_CHECK_UNAVAILABLE');
      }

      // 1. YouTube links
      if (YouTubeExplodeService.isYouTubeUrl(cleanUrl)) {
        busy = false;
        await _startYouTubeExplodeBatchDownload(
          url: cleanUrl,
          title: '',
          thumbnail: null,
          type: selectedType,
        );
        showAdOnOpen = true;
        notifyListeners();
        return;
      }

      // 2. Instagram
      if (cleanUrl.contains('instagram.com')) {
        final playlist = await _api.extractPlaylist(cleanUrl);
        if (playlist.items.isNotEmpty) {
          busy = false;
          for (final item in playlist.items) {
            final itemMeta = await _api.extract(item.url);
            metadata = itemMeta;
            selectedType = _isImageMetadata(itemMeta)
                ? DownloadType.image
                : DownloadType.video;
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
      _status = _errorStatus(error);
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
    if (_playlistChoiceCompleter != null &&
        !_playlistChoiceCompleter!.isCompleted) {
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
