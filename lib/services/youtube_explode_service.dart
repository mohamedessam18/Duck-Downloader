import 'dart:io';

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
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

  /// Returns true for any YouTube video URL (watch, shorts, youtu.be, mobile, embed).
  static bool isYouTubeUrl(String url) {
    final lower = url.toLowerCase();
    // Must be a YouTube domain
    final isYtDomain = lower.contains('youtube.com') || lower.contains('youtu.be');
    if (!isYtDomain) return false;
    // Must NOT be a pure playlist (no video id)
    final isPurePlaylist = !lower.contains('v=') &&
        !lower.contains('youtu.be/') &&
        (lower.contains('list=') || lower.contains('/playlist'));
    if (isPurePlaylist) return false;
    // Video URL patterns
    return lower.contains('/watch') ||        // youtube.com/watch?v=ID
        lower.contains('youtu.be/') ||        // youtu.be/ID
        lower.contains('/shorts/') ||         // youtube.com/shorts/ID
        lower.contains('/embed/') ||          // youtube.com/embed/ID
        lower.contains('/v/') ||              // youtube.com/v/ID (old)
        lower.contains('v=');                 // any ?v=ID param
  }

  /// Returns true for YouTube playlist URLs (with or without a current video).
  static bool isYouTubePlaylistUrl(String url) {
    final lower = url.toLowerCase();
    return (lower.contains('youtube.com') || lower.contains('youtu.be')) &&
        (lower.contains('list=') || lower.contains('/playlist'));
  }


  /// Extracts all videos in a YouTube playlist.
  /// Returns a list of [PlaylistItem] with title and URL.
  Future<({String title, List<PlaylistItem> items})> extractPlaylist(
    String url,
  ) async {
    final playlistId = PlaylistId.parsePlaylistId(url);
    if (playlistId == null) throw Exception('Invalid YouTube playlist URL');

    final playlist = await _yt.playlists.get(playlistId);
    final videos = await _yt.playlists.getVideos(playlistId).toList();

    final items = videos.map((v) {
      return PlaylistItem(
        url: 'https://www.youtube.com/watch?v=${v.id.value}',
        title: v.title,
        thumbnail: v.thumbnails.highResUrl,
        isVideo: true,
      );
    }).toList();

    return (title: playlist.title, items: items);
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
  ///
  /// For YouTube audio-only streams (WebM/Opus), the file is automatically
  /// transcoded to M4A (AAC) so it plays on all devices.
  Future<String> downloadStream({
    required String streamUrl,
    required String title,
    required DownloadType type,
    required String ext,
    void Function(int received, int total)? onProgress,
    void Function()? onTranscoding,
  }) async {
    final root = await getApplicationDocumentsDirectory();
    final subfolder = type == DownloadType.audio
        ? 'Audios'
        : type == DownloadType.image
            ? 'Images'
            : 'Videos';
    final folder = Directory(p.join(root.path, 'Duck Downloader', subfolder));
    await folder.create(recursive: true);

    // YouTube audio is WebM/Opus — transcode to M4A for universal compatibility
    final needsTranscode = type == DownloadType.audio &&
        ext.toLowerCase() == 'webm';
    final downloadExt = needsTranscode ? 'webm' : ext;
    final finalExt = needsTranscode ? 'm4a' : ext;

    final safe = _sanitizeFilename('$title.$downloadExt');
    final webmPath = p.join(folder.path, safe);

    await _dio.download(
      streamUrl,
      webmPath,
      onReceiveProgress: onProgress,
      options: Options(
        // YouTube requires a proper referer or it returns 403
        headers: {
          'Referer': 'https://www.youtube.com/',
          'Origin': 'https://www.youtube.com',
        },
      ),
    );

    if (!needsTranscode) return webmPath;

    // Transcode WebM/Opus → M4A/AAC
    onTranscoding?.call();
    final m4aPath = p.join(
      folder.path,
      _sanitizeFilename('$title.$finalExt'),
    );
    await transcodeWebmToM4a(webmPath, m4aPath);

    // Clean up the temporary .webm file
    try {
      await File(webmPath).delete();
    } catch (_) {}

    return m4aPath;
  }

  /// Transcodes a WebM/Opus audio file to M4A/AAC using FFmpeg.
  /// Throws an [Exception] if FFmpeg fails or is unavailable.
  Future<void> transcodeWebmToM4a(String inputPath, String outputPath) async {
    // -y            : overwrite output without asking
    // -i            : input file
    // -vn           : no video
    // -c:a aac      : encode audio as AAC
    // -b:a 192k     : 192 kbps target bitrate
    // -movflags +faststart : enable streaming-friendly M4A layout
    final command =
        '-y -i "$inputPath" -vn -c:a aac -b:a 192k -movflags +faststart "$outputPath"';

    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getLogsAsString();
      throw Exception('FFmpeg transcoding failed: $logs');
    }
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
