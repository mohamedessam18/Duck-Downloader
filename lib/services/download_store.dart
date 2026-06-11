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
}
