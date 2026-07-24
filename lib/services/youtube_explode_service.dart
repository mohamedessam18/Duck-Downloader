import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/youtube_http_client.dart';

import '../models/download_models.dart';

/// Extracts YouTube video metadata and downloads streams **directly on the
/// client device**, bypassing the backend server entirely.
///
/// Audio downloads use a robust hybrid strategy:
/// 1. Attempt native audio-only stream download.
/// 2. If it hangs (no chunks received within 6s) or gets 403 Forbidden, it
///    automatically falls back to downloading the lowest-resolution muxed MP4
///    stream (which is browser-friendly and never blocked) and extracts the
///    audio track instantly using FFmpeg.
class YouTubeExplodeService {
  YouTubeExplodeService() : _yt = YoutubeExplode(), _dio = Dio();

  YoutubeExplode _yt;
  final Dio _dio;
  String? _currentCookieString;

  void updateCookies(String? netscapeCookieContent) {
    if (netscapeCookieContent == null || netscapeCookieContent.isEmpty) {
      _currentCookieString = null;
      _yt.close();
      _yt = YoutubeExplode();
      return;
    }

    final cookiesList = <String>[];
    final lines = netscapeCookieContent.split('\n');
    for (final line in lines) {
      if (line.trim().isEmpty || line.startsWith('#')) continue;
      final parts = line.split('\t');
      if (parts.length >= 7) {
        final name = parts[5].trim();
        final value = parts[6].trim();
        cookiesList.add('$name=$value');
      }
    }
    _currentCookieString = cookiesList.join('; ');
    _yt.close();
    _yt = YoutubeExplode(httpClient: CookieYoutubeHttpClient(_currentCookieString!));
  }

  void dispose() {
    _yt.close();
    _dio.close();
  }

  // ── URL helpers ────────────────────────────────────────────────────────────

  /// Returns true for any YouTube video or domain URL (watch, shorts, live, clip, embed, youtu.be, youtube-nocookie.com, etc).
  static bool isYouTubeUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('youtube.com') ||
        lower.contains('youtu.be') ||
        lower.contains('youtube-nocookie.com') ||
        lower.contains('youtube');
  }

  /// Returns true for YouTube playlist URLs or any YouTube domain URL with playlist parameters.
  static bool isYouTubePlaylistUrl(String url) {
    final lower = url.toLowerCase();
    final isYtDomain = lower.contains('youtube.com') ||
        lower.contains('youtu.be') ||
        lower.contains('youtube-nocookie.com') ||
        lower.contains('youtube');
    return isYtDomain && (lower.contains('list=') || lower.contains('/playlist'));
  }

  // ── Playlist extraction ────────────────────────────────────────────────────

  /// Extracts all videos in a YouTube playlist.
  Future<({String title, List<PlaylistItem> items})> extractPlaylist(
    String url,
  ) async {
    throw Exception('YouTube downloads are not supported under Google Play policies.');
  }

  // ── Metadata extraction ────────────────────────────────────────────────────

  /// Returns null if the URL is not a recognisable YouTube video URL.
  Future<MediaMetadata?> extractMetadata(String url) async {
    if (!isYouTubeUrl(url)) return null;
    throw Exception('YouTube downloads are not supported under Google Play policies.');
  }

  // ── Audio download (robust hybrid) ──────────────────────────────────────────

  /// Downloads a YouTube audio track with an automatic fallback mechanism:
  /// 1. Try downloading the native audio-only stream.
  /// 2. If it hangs or gets a 403, download the lowest quality muxed stream (fast & unblocked)
  ///    and extract the audio via FFmpeg.
  Future<String> downloadAudioNative({
    required String videoUrl,
    required String title,
    void Function(int received, int total)? onProgress,
    void Function()? onTranscoding,
  }) async {
    throw Exception('YouTube downloads are not supported under Google Play policies.');
  }

  Future<String> downloadVideoNative({
    required String videoUrl,
    required String title,
    int? preferredHeight,
    String? preferredExt,
    void Function(int received, int total)? onProgress,
  }) async {
    throw Exception('YouTube downloads are not supported under Google Play policies.');
  }

  // ── Legacy stream download (Dio) ───────────────────────────────────────────

  /// Downloads any stream URL directly to local storage using Dio.
  /// Prefer [downloadVideoNative] or [downloadAudioNative] for YouTube.
  Future<String> downloadStream({
    required String streamUrl,
    required String title,
    required DownloadType type,
    required String ext,
    void Function(int received, int total)? onProgress,
  }) async {
    if (isYouTubeUrl(streamUrl) || isYouTubePlaylistUrl(streamUrl)) {
      throw Exception('YouTube downloads are not supported under Google Play policies.');
    }
    final root = await getApplicationDocumentsDirectory();
    final subfolder = type == DownloadType.audio
        ? 'Audios'
        : type == DownloadType.image
            ? 'Images'
            : 'Videos';
    final folder = Directory(p.join(root.path, 'Duck Downloader', subfolder));
    await folder.create(recursive: true);

    final filePath = await _getUniqueFilePath(folder.path, '$title.$ext');

    await _dio.download(
      streamUrl,
      filePath,
      onReceiveProgress: onProgress,
      options: Options(
        headers: {
          'Referer': 'https://www.youtube.com/',
          'Origin': 'https://www.youtube.com',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
      ),
    );
    return filePath;
  }

  // ── FFmpeg helpers ─────────────────────────────────────────────────────────

  /// Transcodes/remuxes any audio file to M4A/AAC using FFmpeg.
  ///
  /// - WebM/Opus input → re-encoded to AAC 192 kbps
  /// - MP4/AAC input  → stream-copied (fast remux, no quality loss)
  Future<void> transcodeToM4a(String inputPath, String outputPath) async {
    final ext = p.extension(inputPath).toLowerCase().replaceAll('.', '');
    final isAlreadyAac = ext == 'mp4' || ext == 'm4a';

    // Use executeWithArguments — same pattern as TrimService (proven working)
    final args = [
      '-y',
      '-i', inputPath,
      '-vn',
      '-c:a', isAlreadyAac ? 'copy' : 'aac',
      if (!isAlreadyAac) ...['-b:a', '192k'],
      '-movflags', '+faststart',
      outputPath,
    ];

    final session = await FFmpegKit.executeWithArguments(args);
    final returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      throw Exception(
        'FFmpeg transcode failed: ${logs?.trim() ?? 'unknown error'}',
      );
    }

    final out = File(outputPath);
    if (!await out.exists() || await out.length() <= 0) {
      throw Exception('FFmpeg produced an empty output file.');
    }
  }

  // ── Private helpers ────────────────────────────────────────────────────────

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

  Future<String> _getUniqueFilePath(String folderPath, String filename) async {
    final safeName = _sanitizeFilename(filename);
    var filePath = p.join(folderPath, safeName);
    if (await File(filePath).exists()) {
      final ext = p.extension(safeName);
      final base = p.basenameWithoutExtension(safeName);
      var counter = 1;
      while (await File(filePath).exists()) {
        filePath = p.join(folderPath, '${base}_$counter$ext');
        counter++;
      }
    }
    return filePath;
  }
}

class CookieYoutubeHttpClient extends YoutubeHttpClient {
  CookieYoutubeHttpClient(this.cookieString, [super.httpClient]);

  final String cookieString;

  @override
  Map<String, String> get headers {
    final base = Map<String, String>.from(super.headers);
    if (cookieString.isNotEmpty) {
      base['cookie'] = cookieString;
    }
    return base;
  }
}
