import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/download_models.dart';

/// Extracts YouTube video metadata and stream URLs **directly on the client device**,
/// bypassing the backend server entirely.
///
/// This avoids the "Sign in to confirm you're not a bot" errors that occur when
/// a server IP (e.g. Railway data-center) is blocked by YouTube.
class YouTubeExplodeService {
  YouTubeExplodeService() : _yt = YoutubeExplode(), _dio = Dio();

  final YoutubeExplode _yt;
  final Dio _dio;

  void dispose() {
    _yt.close();
    _dio.close();
  }

  static bool isYouTubeUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('youtube.com/watch') ||
        lower.contains('youtu.be/') ||
        lower.contains('youtube.com/shorts/');
  }

  /// Returns null if the URL is not a recognisable YouTube video URL.
  Future<MediaMetadata?> extractMetadata(String url) async {
    if (!isYouTubeUrl(url)) return null;

    final videoId = VideoId.parseVideoId(url);
    if (videoId == null) return null;

    final video = await _yt.videos.get(videoId);
    final manifest = await _yt.videos.streamsClient.getManifest(videoId);

    // ── Video qualities (muxed = video+audio in one stream) ─────────────────
    final videoFormats = <FormatInfo>[];

    final muxed = manifest.muxed.sortByVideoQuality().reversed.toList();
    for (final stream in muxed) {
      final res = stream.videoResolution;
      final label = '${res.height}p (${stream.container.name.toUpperCase()})';
      videoFormats.add(FormatInfo(
        id: stream.url.toString(),
        label: label,
        ext: stream.container.name,
        height: res.height,
        width: res.width,
        filesize: stream.size.totalBytes,
      ));
    }

    // Video-only (higher quality options)
    final videoOnly = manifest.videoOnly.sortByVideoQuality().reversed.toList();
    for (final stream in videoOnly) {
      final res = stream.videoResolution;
      final label = '${res.height}p HD (${stream.container.name.toUpperCase()})';
      videoFormats.add(FormatInfo(
        id: stream.url.toString(),
        label: label,
        ext: stream.container.name,
        height: res.height,
        width: res.width,
        filesize: stream.size.totalBytes,
      ));
    }

    // ── Audio formats ────────────────────────────────────────────────────────
    final audioFormats = <FormatInfo>[];
    final audioOnly = manifest.audioOnly.sortByBitrate().reversed.toList();
    for (final stream in audioOnly) {
      final bitrateKbps = (stream.bitrate.bitsPerSecond / 1000).round();
      final label = '${bitrateKbps} kbps (${stream.container.name.toUpperCase()})';
      audioFormats.add(FormatInfo(
        id: stream.url.toString(),
        label: label,
        ext: stream.container.name,
        filesize: stream.size.totalBytes,
      ));
    }

    return MediaMetadata(
      url: url,
      title: video.title,
      platform: 'YouTube',
      thumbnail: video.thumbnails.highResUrl,
      duration: _formatDuration(video.duration),
      qualities: videoFormats,
      audioFormats: audioFormats,
    );
  }

  /// Downloads the stream directly to local storage.
  /// [streamUrl] is one of the `FormatInfo.id` values returned by [extractMetadata].
  /// Returns the local file path.
  Future<String> downloadStream({
    required String streamUrl,
    required String title,
    required DownloadType type,
    required String ext,
    void Function(int received, int total)? onProgress,
  }) async {
    final root = await getApplicationDocumentsDirectory();
    final subfolder = type == DownloadType.audio
        ? 'Audios'
        : type == DownloadType.image
            ? 'Images'
            : 'Videos';
    final folder = Directory(p.join(root.path, 'Duck Downloader', subfolder));
    await folder.create(recursive: true);

    final safe = _sanitizeFilename('$title.$ext');
    final filePath = p.join(folder.path, safe);

    await _dio.download(
      streamUrl,
      filePath,
      onReceiveProgress: onProgress,
      options: Options(
        // YouTube requires a proper referer or it returns 403
        headers: {
          'Referer': 'https://www.youtube.com/',
          'Origin': 'https://www.youtube.com',
        },
      ),
    );
    return filePath;
  }

  String _formatDuration(Duration? d) {
    if (d == null) return '';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _sanitizeFilename(String value) {
    return value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]+'), '_')
        .trim()
        .replaceAll(RegExp(r'_{2,}'), '_');
  }
}
