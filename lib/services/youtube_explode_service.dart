import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

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

  final YoutubeExplode _yt;
  final Dio _dio;

  void dispose() {
    _yt.close();
    _dio.close();
  }

  // ── URL helpers ────────────────────────────────────────────────────────────

  /// Returns true for any YouTube video URL (watch, shorts, youtu.be, etc).
  static bool isYouTubeUrl(String url) {
    final lower = url.toLowerCase();
    final isYtDomain =
        lower.contains('youtube.com') || lower.contains('youtu.be');
    if (!isYtDomain) return false;
    final isPurePlaylist = !lower.contains('v=') &&
        !lower.contains('youtu.be/') &&
        (lower.contains('list=') || lower.contains('/playlist'));
    if (isPurePlaylist) return false;
    return lower.contains('/watch') ||
        lower.contains('youtu.be/') ||
        lower.contains('/shorts/') ||
        lower.contains('/embed/') ||
        lower.contains('/v/') ||
        lower.contains('v=');
  }

  /// Returns true for YouTube playlist URLs (with or without a current video).
  static bool isYouTubePlaylistUrl(String url) {
    final lower = url.toLowerCase();
    return (lower.contains('youtube.com') || lower.contains('youtu.be')) &&
        (lower.contains('list=') || lower.contains('/playlist'));
  }

  // ── Playlist extraction ────────────────────────────────────────────────────

  /// Extracts all videos in a YouTube playlist.
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

  // ── Metadata extraction ────────────────────────────────────────────────────

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
      final label =
          '${res.height}p HD (${stream.container.name.toUpperCase()})';
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
      final label =
          '${bitrateKbps} kbps (${stream.container.name.toUpperCase()})';
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
    if (videoId == null) throw Exception('Invalid YouTube video URL');

    final manifest = await _yt.videos.streamsClient.getManifest(videoId);
    final root = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(root.path, 'Duck Downloader', 'Audios'));
    await folder.create(recursive: true);

    final m4aPath = await _getUniqueFilePath(folder.path, '$title.m4a');

    if (manifest.muxed.isEmpty) {
      throw Exception('No streams found to extract audio.');
    }

    // Pick the lowest resolution muxed stream to minimize download size
    final muxedInfo = manifest.muxed.sortByVideoQuality().first;
    final tempMuxedPath = p.join(folder.path, _sanitizeFilename('temp_mux_${DateTime.now().millisecondsSinceEpoch}.mp4'));

    final stream = _yt.videos.streamsClient.get(muxedInfo);
    final file = File(tempMuxedPath);
    final output = file.openWrite();
    var downloaded = 0;
    final total = muxedInfo.size.totalBytes;

    await for (final data in stream) {
      output.add(data);
      downloaded += data.length;
      if (onProgress != null && total > 0) {
        onProgress(downloaded, total);
      }
    }
    await output.flush();
    await output.close();

    // Extract audio track from temp video file
    onTranscoding?.call();
    await transcodeToM4a(tempMuxedPath, m4aPath);

    // Clean up temp video file
    try {
      await File(tempMuxedPath).delete();
    } catch (_) {}

    return m4aPath;
  }

  // ── Video download (robust – fresh manifest) ──────────────────────────────

  /// Downloads a YouTube video by re-fetching a fresh stream manifest at
  /// download time so the CDN URL is guaranteed not to have expired.
  ///
  /// Quality matching logic:
  /// 1. Try to find a muxed stream whose height matches [preferredHeight].
  /// 2. If no exact match, pick the closest muxed stream.
  /// 3. If muxed list is empty, fall back to video-only streams.
  Future<String> downloadVideoNative({
    required String videoUrl,
    required String title,
    int? preferredHeight,
    String? preferredExt,
    void Function(int received, int total)? onProgress,
  }) async {
    final videoId = VideoId.parseVideoId(videoUrl);
    if (videoId == null) throw Exception('Invalid YouTube video URL');

    final manifest = await _yt.videos.streamsClient.getManifest(videoId);
    final root = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(root.path, 'Duck Downloader', 'Videos'));
    await folder.create(recursive: true);

    // ── Pick the best stream from the fresh manifest ─────────────────────────
    StreamInfo? chosen;

    if (manifest.muxed.isNotEmpty) {
      final muxed = manifest.muxed.sortByVideoQuality().reversed.toList();
      if (preferredHeight != null) {
        // Exact match first
        chosen = muxed.cast<StreamInfo?>().firstWhere(
          (s) => (s as MuxedStreamInfo).videoResolution.height == preferredHeight,
          orElse: () => null,
        );
        // Closest match
        chosen ??= muxed.reduce((a, b) {
          final diffA = (a.videoResolution.height - preferredHeight).abs();
          final diffB = (b.videoResolution.height - preferredHeight).abs();
          return diffA <= diffB ? a : b;
        });
      } else {
        chosen = muxed.first; // highest quality
      }
    }

    if (chosen == null && manifest.videoOnly.isNotEmpty) {
      final videoOnly = manifest.videoOnly.sortByVideoQuality().reversed.toList();
      if (preferredHeight != null) {
        chosen = videoOnly.cast<StreamInfo?>().firstWhere(
          (s) => (s as VideoOnlyStreamInfo).videoResolution.height == preferredHeight,
          orElse: () => null,
        );
        chosen ??= videoOnly.reduce((a, b) {
          final diffA = (a.videoResolution.height - preferredHeight).abs();
          final diffB = (b.videoResolution.height - preferredHeight).abs();
          return diffA <= diffB ? a : b;
        });
      } else {
        chosen = videoOnly.first;
      }
    }

    if (chosen == null) {
      throw Exception('No video streams found for this YouTube video.');
    }

    final ext = preferredExt ?? chosen.container.name;
    final filePath = await _getUniqueFilePath(folder.path, '$title.$ext');

    final isVideoOnly = chosen is VideoOnlyStreamInfo;
    if (isVideoOnly) {
      if (manifest.audioOnly.isEmpty) {
        throw Exception('No audio stream found to merge with the high-quality video.');
      }
      final audioStreamInfo = manifest.audioOnly.sortByBitrate().last;

      final tempVideoPath = p.join(folder.path, 'temp_v_${DateTime.now().millisecondsSinceEpoch}.${chosen.container.name}');
      final tempAudioPath = p.join(folder.path, 'temp_a_${DateTime.now().millisecondsSinceEpoch}.${audioStreamInfo.container.name}');

      try {
        // 1. Download Video (80% of progress) using youtube_explode_dart
        final videoStream = _yt.videos.streamsClient.get(chosen);
        final videoFile = File(tempVideoPath);
        final videoOutput = videoFile.openWrite();
        var videoDownloaded = 0;
        final videoTotal = chosen.size.totalBytes;

        await for (final data in videoStream) {
          videoOutput.add(data);
          videoDownloaded += data.length;
          if (onProgress != null && videoTotal > 0) {
            final videoProgress = (videoDownloaded / videoTotal) * 0.8;
            onProgress((videoProgress * 100).toInt(), 100);
          }
        }
        await videoOutput.flush();
        await videoOutput.close();

        // 2. Download Audio (15% of progress) using youtube_explode_dart
        final audioStream = _yt.videos.streamsClient.get(audioStreamInfo);
        final audioFile = File(tempAudioPath);
        final audioOutput = audioFile.openWrite();
        var audioDownloaded = 0;
        final audioTotal = audioStreamInfo.size.totalBytes;

        await for (final data in audioStream) {
          audioOutput.add(data);
          audioDownloaded += data.length;
          if (onProgress != null && audioTotal > 0) {
            final audioProgress = 0.8 + (audioDownloaded / audioTotal) * 0.15;
            onProgress((audioProgress * 100).toInt(), 100);
          }
        }
        await audioOutput.flush();
        await audioOutput.close();

        // 3. Merge video & audio via FFmpeg (5% of progress)
        if (onProgress != null) {
          onProgress(95, 100);
        }

        final mergeArgs = [
          '-y',
          '-i', tempVideoPath,
          '-i', tempAudioPath,
          '-c:v', 'copy',
          '-c:a', 'aac',
          '-map', '0:v:0',
          '-map', '1:a:0',
          '-shortest',
          filePath,
        ];

        final session = await FFmpegKit.executeWithArguments(mergeArgs);
        final returnCode = await session.getReturnCode();

        if (!ReturnCode.isSuccess(returnCode)) {
          final logs = await session.getAllLogsAsString();
          throw Exception(
            'FFmpeg merge failed: ${logs?.trim() ?? 'unknown error'}',
          );
        }

        final outFile = File(filePath);
        if (!await outFile.exists() || await outFile.length() <= 0) {
          throw Exception('FFmpeg produced an empty merged video file.');
        }

        if (onProgress != null) {
          onProgress(100, 100);
        }
      } finally {
        // Clean up temp files
        try {
          final fv = File(tempVideoPath);
          if (fv.existsSync()) fv.deleteSync();
        } catch (_) {}
        try {
          final fa = File(tempAudioPath);
          if (fa.existsSync()) fa.deleteSync();
        } catch (_) {}
      }
    } else {
      // Normal muxed download using youtube_explode_dart
      final stream = _yt.videos.streamsClient.get(chosen);
      final file = File(filePath);
      final output = file.openWrite();
      var downloaded = 0;
      final total = chosen.size.totalBytes;

      await for (final data in stream) {
        output.add(data);
        downloaded += data.length;
        if (onProgress != null && total > 0) {
          onProgress(downloaded, total);
        }
      }
      await output.flush();
      await output.close();
    }
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
