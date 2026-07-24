import 'package:flutter/foundation.dart';

enum DownloadType { video, audio, image }

enum DownloadStatus {
  queued,
  downloading,
  processing,
  paused,
  completed,
  failed,
  cancelled,
}

enum DuckFlow { idle, extracting, ready, downloading, success, error }

enum DuckTab { home, videos, audios, images }

const Object _preserveExternalSaveError = Object();

num? _parseNum(dynamic v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v);
  return null;
}

class FormatInfo {
  const FormatInfo({
    required this.id,
    required this.label,
    this.ext,
    this.height,
    this.width,
    this.filesize,
  });

  final String id;
  final String label;
  final String? ext;
  final int? height;
  final int? width;
  final int? filesize;

  factory FormatInfo.fromJson(Map<String, dynamic> json) {
    return FormatInfo(
      id: json['id']?.toString() ?? json['label']?.toString() ?? 'best',
      label: json['label']?.toString() ?? 'Best',
      ext: json['ext'] as String?,
      height: _parseNum(json['height'])?.toInt(),
      width: _parseNum(json['width'])?.toInt(),
      filesize: _parseNum(json['filesize'])?.toInt(),
    );
  }
}

class MediaMetadata {
  const MediaMetadata({
    required this.url,
    required this.title,
    required this.platform,
    required this.qualities,
    required this.audioFormats,
    this.thumbnail,
    this.duration,
  });

  final String url;
  final String title;
  final String platform;
  final String? thumbnail;
  final String? duration;
  final List<FormatInfo> qualities;
  final List<FormatInfo> audioFormats;

  factory MediaMetadata.fromJson(String url, Map<String, dynamic> json) {
    return MediaMetadata(
      url: url,
      title: json['title']?.toString() ?? 'Untitled',
      platform: json['platform']?.toString() ?? 'Public source',
      thumbnail: json['thumbnail'] as String?,
      duration: json['duration'] as String?,
      qualities: [
        for (final item in (json['qualities'] as List? ?? const []))
          FormatInfo.fromJson(Map<String, dynamic>.from(item as Map)),
      ],
      audioFormats: [
        for (final item in (json['audio_formats'] as List? ?? const []))
          FormatInfo.fromJson(Map<String, dynamic>.from(item as Map)),
      ],
    );
  }
}

class DownloadItem {
  const DownloadItem({
    required this.id,
    required this.url,
    required this.title,
    required this.platform,
    required this.type,
    required this.createdAt,
    required this.status,
    required this.progress,
    required this.favorite,
    this.savedToGallery = false,
    this.savedToMusic = false,
    this.isPrivate = false,
    this.externalSaveError,
    this.thumbnail,
    this.quality,
    this.filePath,
    this.artist,
    this.album,
  });

  final String id;
  final String url;
  final String title;
  final String platform;
  final String? thumbnail;
  final String? quality;
  final DownloadType type;
  final String? filePath;
  final DateTime createdAt;
  final DownloadStatus status;
  final int progress;
  final bool favorite;
  final bool savedToGallery;
  final bool savedToMusic;
  final bool isPrivate;
  final String? externalSaveError;
  final String? artist;
  final String? album;

  bool get isVideo => type == DownloadType.video;
  bool get isAudio => type == DownloadType.audio;
  bool get isImage => type == DownloadType.image;

  DownloadItem copyWith({
    String? id,
    String? url,
    String? title,
    String? platform,
    String? thumbnail,
    String? quality,
    DownloadType? type,
    String? filePath,
    DateTime? createdAt,
    DownloadStatus? status,
    int? progress,
    bool? favorite,
    bool? savedToGallery,
    bool? savedToMusic,
    bool? isPrivate,
    Object? externalSaveError = _preserveExternalSaveError,
    String? artist,
    String? album,
  }) {
    return DownloadItem(
      id: id ?? this.id,
      url: url ?? this.url,
      title: title ?? this.title,
      platform: platform ?? this.platform,
      thumbnail: thumbnail ?? this.thumbnail,
      quality: quality ?? this.quality,
      type: type ?? this.type,
      filePath: filePath ?? this.filePath,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      favorite: favorite ?? this.favorite,
      savedToGallery: savedToGallery ?? this.savedToGallery,
      savedToMusic: savedToMusic ?? this.savedToMusic,
      isPrivate: isPrivate ?? this.isPrivate,
      externalSaveError:
          identical(externalSaveError, _preserveExternalSaveError)
          ? this.externalSaveError
          : externalSaveError as String?,
      artist: artist ?? this.artist,
      album: album ?? this.album,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'url': url,
      'title': title,
      'thumbnail': thumbnail,
      'platform': platform,
      'quality': quality,
      'type': type.name,
      'filePath': filePath,
      'createdAt': createdAt.toIso8601String(),
      'status': status.name,
      'progress': progress,
      'favorite': favorite,
      'savedToGallery': savedToGallery,
      'savedToMusic': savedToMusic,
      'isPrivate': isPrivate,
      'externalSaveError': externalSaveError,
      'artist': artist,
      'album': album,
    };
  }

  factory DownloadItem.fromJson(Map<String, dynamic> json) {
    return DownloadItem(
      id: json['id'] as String,
      url: json['url'] as String,
      title: json['title'] as String,
      thumbnail: json['thumbnail'] as String?,
      platform: json['platform'] as String? ?? 'Public source',
      quality: json['quality'] as String?,
      type: DownloadType.values.cast<DownloadType?>().firstWhere(
        (v) => v?.name == json['type'],
        orElse: () => DownloadType.video,
      ) ?? DownloadType.video,
      filePath: json['filePath'] as String?,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      status: DownloadStatus.values.cast<DownloadStatus?>().firstWhere(
        (s) => s?.name == json['status'],
        orElse: () => DownloadStatus.queued,
      ) ?? DownloadStatus.queued,
      progress: _parseNum(json['progress'])?.toInt() ?? 0,
      favorite: json['favorite'] as bool? ?? false,
      savedToGallery: json['savedToGallery'] as bool? ?? false,
      savedToMusic: json['savedToMusic'] as bool? ?? false,
      isPrivate: json['isPrivate'] as bool? ?? false,
      externalSaveError: json['externalSaveError'] as String?,
      artist: json['artist'] as String?,
      album: json['album'] as String?,
    );
  }
}

class DownloadStatusUpdate {
  const DownloadStatusUpdate({
    required this.progress,
    required this.status,
    this.speed,
    this.eta,
    this.fileUrl,
    this.filename,
    this.error,
  });

  final int progress;
  final DownloadStatus status;
  final String? speed;
  final String? eta;
  final String? fileUrl;
  final String? filename;
  final String? error;

  factory DownloadStatusUpdate.fromJson(Map<String, dynamic> json) {
    final statusName = json['status']?.toString() ?? 'queued';
    return DownloadStatusUpdate(
      progress: _parseNum(json['progress'])?.toInt() ?? 0,
      status:
          DownloadStatus.values.cast<DownloadStatus?>().firstWhere(
            (status) => status?.name == statusName,
            orElse: () => DownloadStatus.failed,
          ) ??
          DownloadStatus.failed,
      speed: json['speed']?.toString(),
      eta: json['eta']?.toString(),
      fileUrl: json['fileUrl']?.toString(),
      filename: json['filename']?.toString(),
      error: json['error']?.toString(),
    );
  }
}

class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.downloadIds,
    required this.createdAt,
  });

  final String id;
  final String name;
  final List<String> downloadIds;
  final DateTime createdAt;

  Playlist copyWith({
    String? id,
    String? name,
    List<String>? downloadIds,
    DateTime? createdAt,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      downloadIds: downloadIds ?? this.downloadIds,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'downloadIds': downloadIds,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'] as String,
      name: json['name'] as String,
      downloadIds: List<String>.from(json['downloadIds'] as List? ?? const []),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class PlaylistItem {
  const PlaylistItem({
    required this.url,
    required this.title,
    this.thumbnail,
    this.width,
    this.height,
    this.source,
    this.isPreview = false,
    this.isVideo = false,
  });

  final String url;
  final String title;
  final String? thumbnail;
  final int? width;
  final int? height;
  final String? source;
  final bool isPreview;
  final bool isVideo;

  factory PlaylistItem.fromJson(Map<String, dynamic> json) {
    debugPrint('DEBUG JSON: url=${json['url']} isVideo=${json['isVideo']} keys=${json.keys.toList()}');
    return PlaylistItem(
      url: json['url']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      thumbnail: json['thumbnail']?.toString(),
      width: _parseNum(json['width'])?.toInt(),
      height: _parseNum(json['height'])?.toInt(),
      source: json['source']?.toString(),
      isPreview: json['isPreview'] as bool? ?? false,
      isVideo: json['isVideo'] as bool? ?? false,
    );
  }
}

class PlaylistExtractResponse {
  const PlaylistExtractResponse({
    required this.title,
    required this.platform,
    required this.items,
  });

  final String title;
  final String platform;
  final List<PlaylistItem> items;

  factory PlaylistExtractResponse.fromJson(Map<String, dynamic> json) {
    return PlaylistExtractResponse(
      title: json['title']?.toString() ?? '',
      platform: json['platform']?.toString() ?? '',
      items: [
        for (final item in (json['items'] as List? ?? const []))
          PlaylistItem.fromJson(Map<String, dynamic>.from(item as Map)),
      ],
    );
  }
}

class BackendCookiesInfo {
  const BackendCookiesInfo({
    required this.active,
    required this.size,
    this.filename,
  });

  final bool active;
  final int size;
  final String? filename;

  factory BackendCookiesInfo.fromJson(Map<String, dynamic> json) {
    return BackendCookiesInfo(
      active: json['active'] as bool? ?? false,
      size: _parseNum(json['size'])?.toInt() ?? 0,
      filename: json['filename']?.toString(),
    );
  }
}
