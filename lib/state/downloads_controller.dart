import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/download_models.dart';
import '../services/api_client.dart';
import '../services/clipboard_service.dart';
import '../services/download_store.dart';
import '../services/file_service.dart';
import '../services/license_store.dart';

class DuckDownloadsController extends ChangeNotifier {
  DuckDownloadsController({
    required DuckApiClient api,
    required DuckClipboardService clipboard,
    required DuckFileService files,
    required DownloadStore store,
    required LicenseStore licenseStore,
  }) : _api = api,
       _clipboard = clipboard,
       _files = files,
       _store = store,
       _licenseStore = licenseStore {
    _downloads = _store.readDownloads();
    isProActive = _licenseStore.isActive;
    licenseKey = _licenseStore.licenseKey;
    licenseStatus = isProActive
        ? 'Lifetime Pro is active.'
        : 'Enter your lifetime license key.';
    if (licenseKey != null) {
      unawaited(verifyLicense(silent: true));
    }
  }

  final DuckApiClient _api;
  final DuckClipboardService _clipboard;
  final DuckFileService _files;
  final DownloadStore _store;
  final LicenseStore _licenseStore;

  List<DownloadItem> _downloads = [];
  DuckFlow flow = DuckFlow.idle;
  DuckTab tab = DuckTab.home;
  String status = 'Tap the duck';
  MediaMetadata? metadata;
  DownloadType selectedType = DownloadType.video;
  String quality = 'Best';
  bool busy = false;
  bool licenseBusy = false;
  bool isProActive = false;
  String? licenseKey;
  String licenseStatus = 'Enter your lifetime license key.';
  String? activeId;
  DownloadItem? playerItem;
  final Set<String> controlPendingIds = {};

  List<DownloadItem> get downloads => List.unmodifiable(_downloads);
  List<DownloadItem> get videos => _completed(DownloadType.video);
  List<DownloadItem> get audios => _completed(DownloadType.audio);
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
              item.type == type && item.status == DownloadStatus.completed,
        )
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  void setTab(DuckTab next) {
    tab = next;
    notifyListeners();
  }

  void openPlayer(DownloadItem item) {
    playerItem = item;
    notifyListeners();
  }

  void closePlayer() {
    playerItem = null;
    notifyListeners();
  }

  Future<void> pasteAndExtract() async {
    if (busy) return;
    busy = true;
    flow = DuckFlow.extracting;
    status = 'Checking link...';
    metadata = null;
    notifyListeners();

    try {
      final url = await _clipboard.readText();
      if (url == null || !_isPublicMediaCandidate(url)) {
        throw Exception('Copy a public social media link first.');
      }
      final media = await _api.extract(url);
      metadata = media;
      selectedType = DownloadType.video;
      quality = _firstQuality(media, DownloadType.video);
      flow = DuckFlow.ready;
      status = 'Choose video or audio';
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
        premiumNoWatermark: isProActive,
        licenseKey: isProActive ? licenseKey : null,
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

  Future<bool> activateLicense(String value) async {
    final key = value.trim();
    if (key.isEmpty || licenseBusy) return false;
    licenseBusy = true;
    licenseStatus = 'Checking license...';
    notifyListeners();
    try {
      final active = await _api.activateLicense(key);
      isProActive = active;
      licenseKey = active ? key : null;
      await _licenseStore.save(licenseKey: key, active: active);
      licenseStatus = active
          ? 'Lifetime Pro is active.'
          : 'This license key is not valid.';
      return active;
    } catch (error) {
      licenseStatus = _cleanError(error);
      return false;
    } finally {
      licenseBusy = false;
      notifyListeners();
    }
  }

  Future<bool> verifyLicense({bool silent = false}) async {
    final key = licenseKey?.trim();
    if (key == null || key.isEmpty || licenseBusy) return false;
    licenseBusy = true;
    if (!silent) {
      licenseStatus = 'Restoring Pro...';
      notifyListeners();
    }
    try {
      final active = await _api.verifyLicense(key);
      isProActive = active;
      await _licenseStore.save(licenseKey: key, active: active);
      licenseStatus = active
          ? 'Lifetime Pro is active.'
          : 'Saved license is no longer valid.';
      return active;
    } catch (error) {
      if (!silent) licenseStatus = _cleanError(error);
      return false;
    } finally {
      licenseBusy = false;
      notifyListeners();
    }
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
              status: update.status,
            );
            await _saveItem(next);

            if (update.status == DownloadStatus.completed &&
                update.fileUrl != null) {
              final filePath = await _files.downloadRemoteFile(
                url: _api.absoluteFileUrl(update.fileUrl!),
                filename:
                    update.filename ??
                    '${baseItem.title}.${baseItem.type == DownloadType.audio ? 'mp3' : 'mp4'}',
                type: baseItem.type,
              );
              next = next.copyWith(
                filePath: filePath,
                progress: 100,
                status: DownloadStatus.completed,
              );
              await _saveItem(next);
              metadata = null;
              flow = DuckFlow.success;
              status = 'Download complete';
            }

            if (update.status == DownloadStatus.failed) {
              await _saveItem(next.copyWith(status: DownloadStatus.failed));
              flow = DuckFlow.error;
              status = update.error ?? 'Download failed.';
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
          onError: (_) {
            flow = DuckFlow.error;
            status = 'Connection to download server failed.';
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
    final formats = type == DownloadType.video
        ? media.qualities
        : media.audioFormats;
    if (formats.isEmpty) {
      return type == DownloadType.audio ? 'Best audio' : 'Best';
    }
    return formats.first.label;
  }

  bool _isPublicMediaCandidate(String value) {
    return RegExp(
      r'^https?:\/\/[^\s/$.?#].[^\s]*$',
      caseSensitive: false,
    ).hasMatch(value.trim());
  }

  String _cleanError(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
  }
}
