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
import 'stream_quality.dart';
import './crash_reporting_service.dart';

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

  /// How long a stream may go without delivering a byte before it is
  /// abandoned and retried a different way.
  ///
  /// YouTube throttles streams it does not like down to a standstill rather
  /// than refusing them, so "stopped moving" is a distinct failure from "the
  /// connection dropped" and needs its own bound. 45s is long enough to ride
  /// out a bad moment on mobile data and short enough to not look hung.
  static const _stallSeconds = 45;

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

  YoutubeExplode get _freshYt {
    try {
      _yt.close();
    } catch (_) {}
    _yt = (_currentCookieString != null && _currentCookieString!.isNotEmpty)
        ? YoutubeExplode(httpClient: CookieYoutubeHttpClient(_currentCookieString!))
        : YoutubeExplode();
    return _yt;
  }

  // ── Playlist extraction ────────────────────────────────────────────────────

  /// Extracts all videos in a YouTube playlist.
  Future<({String title, List<PlaylistItem> items})> extractPlaylist(
    String url,
  ) async {
    final yt = _freshYt;
    final playlist = await yt.playlists.get(url);
    final videos = await yt.playlists.getVideos(playlist.id).toList();
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

    final yt = _freshYt;
    final video = await yt.videos.get(videoId);
    final manifest = await yt.videos.streamsClient.getManifest(videoId);

    final qualityByHeight = <int, FormatInfo>{};

    // Extract all video streams (both videoOnly and muxed)
    final allVideoStreams = [...manifest.videoOnly, ...manifest.muxed];
    for (final s in allVideoStreams) {
      final h = s.videoResolution.height;
      if (h <= 0) continue;

      String label;
      if (h >= 2160) {
        label = '4K (2160p)';
      } else if (h >= 1440) {
        label = '2K (1440p)';
      } else if (h >= 1080) {
        label = '1080p';
      } else if (h >= 720) {
        label = '720p';
      } else if (h >= 480) {
        label = '480p';
      } else if (h >= 360) {
        label = '360p';
      } else if (h >= 240) {
        label = '240p';
      } else {
        label = '${h}p';
      }

      // Store the best stream candidate for each resolution height
      if (!qualityByHeight.containsKey(h) ||
          (s.size.totalBytes > (qualityByHeight[h]?.filesize ?? 0))) {
        qualityByHeight[h] = FormatInfo(
          id: '$h',
          label: label,
          ext: 'mp4',
          height: h,
          width: s.videoResolution.width,
          filesize: s.size.totalBytes,
        );
      }
    }

    // Sort descending by height (4K -> 2K -> 1080p -> 720p -> 480p -> 360p)
    final sortedHeights = qualityByHeight.keys.toList()..sort((a, b) => b.compareTo(a));
    final qualities = sortedHeights.map((h) => qualityByHeight[h]!).toList();

    // Audio-only stream
    final audioFormats = <FormatInfo>[];
    if (manifest.audioOnly.isNotEmpty) {
      final bestAudio = manifest.audioOnly.withHighestBitrate();
      final audioExt = bestAudio.container.name == 'webm' ? 'm4a' : bestAudio.container.name;
      audioFormats.add(FormatInfo(
        id: 'audio_best',
        label: 'Audio only (M4A)',
        ext: audioExt,
        filesize: bestAudio.size.totalBytes,
      ));
    }

    return MediaMetadata(
      url: url,
      title: video.title,
      thumbnail: video.thumbnails.highResUrl,
      platform: 'YouTube',
      duration: _formatDuration(video.duration),
      qualities: qualities,
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

    final yt = _freshYt;
    final manifest = await yt.videos.streamsClient.getManifest(videoId);
    final root = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(root.path, 'Duck Downloader', 'Audios'));
    await folder.create(recursive: true);

    final safeTitle = _sanitizeFilename(title);

    // Try audio-only stream first with a chunk timeout
    try {
      final audioStream = manifest.audioOnly.withHighestBitrate();
      final ext = audioStream.container.name; // webm or mp4
      final rawPath = await _getUniqueFilePath(folder.path, '$safeTitle.$ext');

      await downloadStreamWithStallTimeout(
        streamUrl: audioStream.url.toString(),
        savePath: rawPath,
        onProgress: onProgress,
        timeoutSeconds: 8,
      );

      // Transcode to M4A
      onTranscoding?.call();
      final m4aPath = rawPath.replaceAll(RegExp(r'\.\w+$'), '.m4a');
      try {
        await transcodeToM4a(rawPath, m4aPath);
      } finally {
        // Same reason as the merge above: the raw download carries the video's
        // own name, so a failed transcode used to leave a duplicate on show.
        await _deleteQuietly(rawPath);
      }
      return m4aPath;
    } catch (_) {
      // Fallback: download lowest muxed stream and extract audio
    }

    onTranscoding?.call();
    // `.last` on an empty list throws StateError, and YouTube now serves many
    // videos with no muxed streams at all — so the fallback for a failed
    // audio-only download was itself a crash rather than an error the caller
    // could report.
    final sortedMuxed = manifest.muxed.sortByVideoQuality();
    if (sortedMuxed.isEmpty) {
      throw Exception(
        'YouTube did not offer a downloadable audio stream for this video.',
      );
    }
    final lowestMuxed = sortedMuxed.last;
    final muxedPath = await _getUniqueFilePath(folder.path, '${safeTitle}_muxed.mp4');
    await downloadStreamWithStallTimeout(
      streamUrl: lowestMuxed.url.toString(),
      savePath: muxedPath,
      onProgress: onProgress,
    );

    final m4aPath = await _getUniqueFilePath(folder.path, '$safeTitle.m4a');
    try {
      await transcodeToM4a(muxedPath, m4aPath);
    } finally {
      await _deleteQuietly(muxedPath);
    }
    return m4aPath;
  }

  /// True when this stream can be dropped into an MP4 without re-encoding.
  ///
  /// The merge runs `-c:v copy` into a `.mp4`, and VP9 and AV1 have no MP4
  /// tag in most FFmpeg builds — the merge fails outright rather than falling
  /// back. YouTube offers all three codecs at the same resolutions, so which
  /// one gets picked was previously a matter of luck.
  static bool _isMp4Friendly(VideoOnlyStreamInfo stream) {
    final codec = stream.videoCodec.toLowerCase();
    return codec.startsWith('avc') || codec.startsWith('h264');
  }

  /// The stream to download for a request of [ceiling] pixels high.
  ///
  /// Resolution is decided first and codec second. Picking the codec first
  /// looks tempting — H.264 copies straight into the MP4 while VP9 and AV1
  /// have to be re-encoded — but YouTube only offers 1440p and 2160p in those
  /// newer codecs, so preferring copyable streams outright means asking for 4K
  /// and silently getting 1080p. That is the same class of bug as the sort
  /// order this replaced; a slow download is better than a quiet downgrade.
  static VideoOnlyStreamInfo? _pickVideoOnly(
    Iterable<VideoOnlyStreamInfo> streams, {
    int? ceiling,
  }) {
    final target = bestAtOrBelow<VideoOnlyStreamInfo>(
      streams,
      (s) => s.videoResolution.height,
      ceiling: ceiling,
    );
    if (target == null) return null;

    final height = target.videoResolution.height;
    final sameHeight =
        streams.where((s) => s.videoResolution.height == height);
    final copyable = sameHeight.where(_isMp4Friendly);
    return copyable.isNotEmpty ? copyable.first : target;
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

    final yt = _freshYt;
    final manifest = await yt.videos.streamsClient.getManifest(videoId);
    final root = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(root.path, 'Duck Downloader', 'Videos'));
    await folder.create(recursive: true);

    final safeTitle = _sanitizeFilename(title);

    // A muxed stream needs no merge at all, so take one when it is exactly
    // what was asked for.
    if (preferredHeight != null) {
      final exact = manifest.muxed
          .where((s) => s.videoResolution.height == preferredHeight);
      if (exact.isNotEmpty) {
        final filePath = await _getUniqueFilePath(
          folder.path,
          '$safeTitle.${preferredExt ?? 'mp4'}',
        );
        await downloadStreamWithStallTimeout(
          streamUrl: exact.first.url.toString(),
          savePath: filePath,
          onProgress: onProgress,
          timeoutSeconds: _stallSeconds,
        );
        return filePath;
      }
    }

    // Otherwise merge the best video-only stream with the best audio.
    final selectedVideoOnly = _pickVideoOnly(
      manifest.videoOnly,
      ceiling: preferredHeight,
    );

    if (selectedVideoOnly != null && manifest.audioOnly.isNotEmpty) {
      final bestAudio = manifest.audioOnly.withHighestBitrate();
      final tempVideoPath =
          await _getUniqueFilePath(folder.path, '${safeTitle}_temp_v.mp4');
      // Named for what it is. Calling an Opus/WebM stream ".m4a" left FFmpeg
      // to work it out, and left a mislabelled orphan behind on failure.
      final tempAudioPath = await _getUniqueFilePath(
        folder.path,
        '${safeTitle}_temp_a.${bestAudio.container.name}',
      );
      final finalFilePath =
          await _getUniqueFilePath(folder.path, '$safeTitle.mp4');

      try {
        // 1. Video stream (0 - 70%)
        await downloadStreamWithStallTimeout(
          streamUrl: selectedVideoOnly.url.toString(),
          savePath: tempVideoPath,
          timeoutSeconds: _stallSeconds,
          onProgress: (rx, total) {
            if (total > 0 && onProgress != null) {
              onProgress((rx / total * 70).toInt(), 100);
            }
          },
        );

        // 2. Audio stream (70 - 90%)
        await downloadStreamWithStallTimeout(
          streamUrl: bestAudio.url.toString(),
          savePath: tempAudioPath,
          timeoutSeconds: _stallSeconds,
          onProgress: (rx, total) {
            if (total > 0 && onProgress != null) {
              onProgress(70 + (rx / total * 20).toInt(), 100);
            }
          },
        );

        // 3. Merge (90 - 100%)
        //
        // The cleanup has to be in a finally. It used to sit after the merge,
        // so any failure past this point — an FFmpeg error, a cancelled job,
        // the process being killed mid-download — left `<title>_temp_a.m4a`
        // behind. That orphan is named after the video and carried an audio
        // extension, so it showed up in the user's audio folders as a phantom
        // copy.
        onProgress?.call(95, 100);
        await mergeVideoAndAudio(
          tempVideoPath,
          tempAudioPath,
          finalFilePath,
          copyVideo: _isMp4Friendly(selectedVideoOnly),
        );
        return finalFilePath;
      } catch (error, stackTrace) {
        await _deleteQuietly(finalFilePath);
        // The audio path has always had a second attempt for exactly this —
        // a refused or stalled stream. Video had none, so one 403 on one of
        // two streams ended the download with nothing to show for it.
        reportError(error, stackTrace, reason: 'youtube-merge-download');
        final fallback = await _downloadBestMuxed(
          manifest: manifest,
          folder: folder,
          safeTitle: safeTitle,
          preferredHeight: preferredHeight,
          onProgress: onProgress,
        );
        if (fallback != null) return fallback;
        rethrow;
      } finally {
        await _deleteQuietly(tempVideoPath);
        await _deleteQuietly(tempAudioPath);
      }
    }

    final fallback = await _downloadBestMuxed(
      manifest: manifest,
      folder: folder,
      safeTitle: safeTitle,
      preferredHeight: preferredHeight,
      onProgress: onProgress,
    );
    if (fallback != null) return fallback;

    throw Exception('No playable video stream found for YouTube video.');
  }

  /// Downloads the best muxed stream, which needs no merge and no FFmpeg.
  ///
  /// Returns null when the video has no muxed stream at all — increasingly
  /// common, and the reason this is a nullable helper rather than a `.last`
  /// on a list that is often empty.
  Future<String?> _downloadBestMuxed({
    required StreamManifest manifest,
    required Directory folder,
    required String safeTitle,
    int? preferredHeight,
    void Function(int received, int total)? onProgress,
  }) async {
    final best = bestAtOrBelow<MuxedStreamInfo>(
      manifest.muxed,
      (s) => s.videoResolution.height,
      ceiling: preferredHeight,
    );
    if (best == null) return null;
    final filePath = await _getUniqueFilePath(folder.path, '$safeTitle.mp4');
    await downloadStreamWithStallTimeout(
      streamUrl: best.url.toString(),
      savePath: filePath,
      onProgress: onProgress,
      timeoutSeconds: _stallSeconds,
    );
    return filePath;
  }

  /// Merges a video-only file and an audio-only file into a single MP4 container using FFmpeg.
  /// Muxes a video-only and an audio-only file into one MP4.
  ///
  /// [copyVideo] must be false for VP9 and AV1. Those have no MP4 tag in most
  /// FFmpeg builds, so `-c:v copy` fails the whole merge — and YouTube serves
  /// them at the same resolutions as H.264, so whether a download worked came
  /// down to which codec happened to be chosen.
  Future<void> mergeVideoAndAudio(
    String videoPath,
    String audioPath,
    String outputPath, {
    bool copyVideo = true,
  }) async {
    final args = [
      '-y',
      '-i', videoPath,
      '-i', audioPath,
      '-c:v', if (copyVideo) 'copy' else 'libx264',
      '-c:a', 'aac',
      '-movflags', '+faststart',
      outputPath,
    ];

    final session = await FFmpegKit.executeWithArguments(args);
    final returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      throw Exception('FFmpeg video/audio merge failed: ${logs?.trim() ?? 'unknown error'}');
    }

    final out = File(outputPath);
    if (!await out.exists() || await out.length() <= 0) {
      throw Exception('FFmpeg produced an empty merged output file.');
    }
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

  /// Downloads a stream URL to [savePath], abandoning it if it stops moving.
  ///
  /// The previous version built a `Completer` and a `Timer` that completed it
  /// with a `TimeoutException`, but nothing ever raced them: the code did
  /// `await dio.download(...)` and only reached `await completer.future`
  /// afterwards. A stream that stalled forever blocked on the first await and
  /// the timer's error was never seen, so the chunk timeout the audio fallback
  /// depends on did nothing at all — the download hung until Dio's own
  /// 15-minute receive timeout, and then reported a network problem.
  ///
  /// A `CancelToken` is what actually interrupts an in-flight Dio request.
  Future<void> downloadStreamWithStallTimeout({
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
      await dio.download(streamUrl, savePath, onReceiveProgress: onProgress);
      return;
    }

    final cancelToken = CancelToken();
    var stalled = false;
    Timer? stallTimer;

    void restartStallTimer() {
      stallTimer?.cancel();
      stallTimer = Timer(Duration(seconds: timeoutSeconds), () {
        stalled = true;
        cancelToken.cancel('stalled');
      });
    }

    restartStallTimer();
    try {
      await dio.download(
        streamUrl,
        savePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          restartStallTimer();
          onProgress?.call(received, total);
        },
      );
    } on DioException catch (error) {
      // Say which one it was. "Cancelled" tells the caller nothing, and this
      // message is what ends up in front of the user.
      if (stalled) {
        throw TimeoutException(
          'The stream stopped sending data for ${timeoutSeconds}s.',
        );
      }
      rethrow;
    } finally {
      stallTimer?.cancel();
      dio.close(force: true);
    }
  }

  String _formatDuration(Duration? d) {
    if (d == null) return '';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _sanitizeFilename(String value, {int maxLength = 60}) {
    var cleaned = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]+'), '_')
        .trim()
        .replaceAll(RegExp(r'_{2,}'), '_')
        .trim();
    if (cleaned.length > maxLength) {
      cleaned = cleaned.substring(0, maxLength).trim();
    }
    return cleaned.isEmpty ? 'duck-download' : cleaned;
  }

  /// Deletes a working file, ignoring the case where it was never created.
  ///
  /// Only ever used for Duck's own intermediates, so a failure here is not
  /// worth surfacing — but leaving one behind is, which is why every caller
  /// runs it from a finally.
  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Removes intermediates orphaned by an earlier run.
  ///
  /// Builds before the finally blocks above could strand `_temp_a.m4a`,
  /// `_temp_v.mp4` and `_muxed.mp4` files in the download folders, where they
  /// appear to the user as duplicate tracks. Fixing the leak does not clean up
  /// what already leaked, so sweep once on launch.
  static Future<void> cleanOrphanedWorkFiles() async {
    const suffixes = ['_temp_a.m4a', '_temp_v.mp4', '_muxed.mp4'];
    try {
      final root = await getApplicationDocumentsDirectory();
      for (final name in ['Videos', 'Audios']) {
        final folder = Directory(p.join(root.path, 'Duck Downloader', name));
        if (!await folder.exists()) continue;
        await for (final entity in folder.list()) {
          if (entity is! File) continue;
          if (suffixes.any(entity.path.endsWith)) {
            await _deleteQuietly(entity.path);
          }
        }
      }
    } catch (error, stackTrace) {
      reportError(error, stackTrace, reason: 'orphan-sweep');
    }
  }

  Future<String> _getUniqueFilePath(String folderPath, String filename) async {
    final ext = p.extension(filename);
    final base = p.basenameWithoutExtension(filename);
    final safeBase = _sanitizeFilename(base, maxLength: 60);
    final safeName = '$safeBase$ext';
    var filePath = p.join(folderPath, safeName);
    if (await File(filePath).exists()) {
      var counter = 1;
      while (await File(filePath).exists()) {
        filePath = p.join(folderPath, '${safeBase}_$counter$ext');
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
