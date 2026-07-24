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
    final playlist = await _yt.playlists.get(url);
    final videos = await _yt.playlists.getVideos(playlist.id).toList();
    final items = <PlaylistItem>[];
    for (final v in videos) {
      final videoUrl = 'https://www.youtube.com/watch?v=${v.id.value}';
      items.add(PlaylistItem(
        url: videoUrl,
        title: v.title,
        thumbnail: v.thumbnails.highResUrl,
        isVideo: true,
      ));
    }
    return (title: playlist.title, items: items);
  }

  // ── Metadata extraction ────────────────────────────────────────────────────

  /// Returns null if the URL is not a recognisable YouTube video URL.
  Future<MediaMetadata?> extractMetadata(String url) async {
    if (!isYouTubeUrl(url)) return null;
    final videoId = VideoId.parseVideoId(url);
    if (videoId == null) return null;

    final video = await _yt.videos.get(videoId);
    final manifest = await _yt.videos.streamsClient.getManifest(videoId);

    final qualities = <FormatInfo>[];
    final audioFormats = <FormatInfo>[];

    // Muxed (video+audio) streams
    for (final s in manifest.muxed.sortByVideoQuality()) {
      final label = s.videoQuality.name;
      qualities.add(FormatInfo(
        id: label,
        label: label,
        ext: 'mp4',
        height: s.videoResolution.height,
        width: s.videoResolution.width,
        filesize: s.size.totalBytes,
      ));
    }

    // Audio-only stream
    final bestAudio = manifest.audioOnly.withHighestBitrate();
    final audioExt = bestAudio.container.name == 'webm' ? 'm4a' : bestAudio.container.name;
    audioFormats.add(FormatInfo(
      id: 'audio_best',
      label: 'Audio only (M4A)',
      ext: audioExt,
      filesize: bestAudio.size.totalBytes,
    ));

    // Deduplicate by label (keep highest quality per label)
    final seen = <String>{};
    final uniqueQualities = qualities.reversed
        .where((q) => seen.add(q.label))
        .toList()
        .reversed
        .toList();

    return MediaMetadata(
      url: url,
      title: video.title,
      thumbnail: video.thumbnails.highResUrl,
      platform: 'YouTube',
      duration: _formatDuration(video.duration),
      qualities: uniqueQualities,
      audioFormats: audioFormats,
    );
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
    final videoId = VideoId.parseVideoId(videoUrl);
    if (videoId == null) throw Exception('Invalid YouTube URL: $videoUrl');

    final manifest = await _yt.videos.streamsClient.getManifest(videoId);
    final root = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(root.path, 'Duck Downloader', 'Audios'));
    await folder.create(recursive: true);

    final safeTitle = _sanitizeFilename(title);

    // Try audio-only stream first with a chunk timeout
    try {
      final audioStream = manifest.audioOnly.withHighestBitrate();
      final ext = audioStream.container.name; // webm or mp4
      final rawPath = await _getUniqueFilePath(folder.path, '$safeTitle.$ext');

      await _downloadStreamWithTimeout(
        streamUrl: audioStream.url.toString(),
        savePath: rawPath,
        onProgress: onProgress,
        timeoutSeconds: 8,
      );

      // Transcode to M4A
      onTranscoding?.call();
      final m4aPath = rawPath.replaceAll(RegExp(r'\.\w+$'), '.m4a');
      await transcodeToM4a(rawPath, m4aPath);
      try {
        await File(rawPath).delete();
      } catch (_) {}
      return m4aPath;
    } catch (_) {
      // Fallback: download lowest muxed stream and extract audio
    }

    onTranscoding?.call();
    final lowestMuxed = manifest.muxed.sortByVideoQuality().last;
    final muxedPath = await _getUniqueFilePath(folder.path, '${safeTitle}_muxed.mp4');
    await _downloadStreamWithTimeout(
      streamUrl: lowestMuxed.url.toString(),
      savePath: muxedPath,
      onProgress: onProgress,
    );

    final m4aPath = await _getUniqueFilePath(folder.path, '$safeTitle.m4a');
    await transcodeToM4a(muxedPath, m4aPath);
    try {
      await File(muxedPath).delete();
    } catch (_) {}
    return m4aPath;
  }

  Future<String> downloadVideoNative({
    required String videoUrl,
    required String title,
    int? preferredHeight,
    String? preferredExt,
    void Function(int received, int total)? onProgress,
  }) async {
    final videoId = VideoId.parseVideoId(videoUrl);
    if (videoId == null) throw Exception('Invalid YouTube URL: $videoUrl');

    final manifest = await _yt.videos.streamsClient.getManifest(videoId);
    final root = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(root.path, 'Duck Downloader', 'Videos'));
    await folder.create(recursive: true);

    final safeTitle = _sanitizeFilename(title);

    // Pick best muxed stream matching preferred height
    MuxedStreamInfo stream;
    final sorted = manifest.muxed.sortByVideoQuality();
    if (preferredHeight != null) {
      stream = sorted.lastWhere(
        (s) => s.videoResolution.height <= preferredHeight,
        orElse: () => sorted.last,
      );
    } else {
      stream = sorted.last; // highest quality
    }

    final ext = preferredExt ?? 'mp4';
    final filePath = await _getUniqueFilePath(folder.path, '$safeTitle.$ext');
    await _downloadStreamWithTimeout(
      streamUrl: stream.url.toString(),
      savePath: filePath,
      onProgress: onProgress,
    );
    return filePath;
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

  /// Downloads a stream URL to [savePath] with an optional chunk-timeout.
  Future<void> _downloadStreamWithTimeout({
    required String streamUrl,
    required String savePath,
    void Function(int received, int total)? onProgress,
    int? timeoutSeconds,
  }) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 15),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.6099.144 Mobile Safari/537.36',
      },
    ));

    if (timeoutSeconds == null) {
      await dio.download(
        streamUrl,
        savePath,
        onReceiveProgress: onProgress,
      );
      return;
    }

    final completer = Completer<void>();
    Timer? chunkTimer;

    void resetTimer() {
      chunkTimer?.cancel();
      chunkTimer = Timer(Duration(seconds: timeoutSeconds), () {
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException('No chunks received within ${timeoutSeconds}s'),
          );
        }
      });
    }

    resetTimer();

    try {
      await dio.download(
        streamUrl,
        savePath,
        onReceiveProgress: (received, total) {
          resetTimer();
          onProgress?.call(received, total);
        },
      );
      chunkTimer?.cancel();
      if (!completer.isCompleted) completer.complete();
    } catch (e) {
      chunkTimer?.cancel();
      if (!completer.isCompleted) completer.completeError(e);
      rethrow;
    }

    await completer.future;
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
