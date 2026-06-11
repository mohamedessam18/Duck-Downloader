enum DownloadType { video, audio }

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

enum DuckTab { home, videos, audios }

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
      height: (json['height'] as num?)?.toInt(),
      width: (json['width'] as num?)?.toInt(),
      filesize: (json['filesize'] as num?)?.toInt(),
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
    this.thumbnail,
    this.quality,
    this.filePath,
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

  bool get isVideo => type == DownloadType.video;
  bool get isAudio => type == DownloadType.audio;

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
      type: DownloadType.values.byName(json['type'] as String? ?? 'video'),
      filePath: json['filePath'] as String?,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      status: DownloadStatus.values.byName(
        json['status'] as String? ?? 'queued',
      ),
      progress: (json['progress'] as num?)?.toInt() ?? 0,
      favorite: json['favorite'] as bool? ?? false,
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
    return DownloadStatusUpdate(
      progress: (json['progress'] as num?)?.toInt() ?? 0,
      status: DownloadStatus.values.byName(
        json['status']?.toString() ?? 'queued',
      ),
      speed: json['speed'] as String?,
      eta: json['eta'] as String?,
      fileUrl: json['fileUrl'] as String?,
      filename: json['filename'] as String?,
      error: json['error'] as String?,
    );
  }
}
