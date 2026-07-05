import 'package:hive/hive.dart';

import '../models/download_models.dart';

class DownloadStore {
  DownloadStore(this._box);

  final Box _box;

  List<DownloadItem> readDownloads() {
    final raw = _box.get('downloads', defaultValue: <dynamic>[]) as List;
    return [
      for (final item in raw)
        DownloadItem.fromJson(Map<String, dynamic>.from(item as Map)),
    ];
  }

  Future<void> writeDownloads(List<DownloadItem> downloads) {
    return _box.put('downloads', [for (final item in downloads) item.toJson()]);
  }

  bool readAutoSaveVideos() {
    return _box.get('autoSaveVideos', defaultValue: true) as bool;
  }

  Future<void> writeAutoSaveVideos(bool enabled) {
    return _box.put('autoSaveVideos', enabled);
  }

  bool readEnableClipboardDetection() {
    return _box.get('enableClipboardDetection', defaultValue: true) as bool;
  }

  Future<void> writeEnableClipboardDetection(bool enabled) {
    return _box.put('enableClipboardDetection', enabled);
  }

  Future<DownloadItem> upsert(DownloadItem item) async {
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
    await writeDownloads(items);
    return item;
  }

  Future<void> delete(String id) async {
    final items = readDownloads()..removeWhere((item) => item.id == id);
    await writeDownloads(items);
  }

  List<Playlist> readPlaylists() {
    final raw = _box.get('playlists', defaultValue: <dynamic>[]) as List;
    return [
      for (final item in raw)
        Playlist.fromJson(Map<String, dynamic>.from(item as Map)),
    ];
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
}
