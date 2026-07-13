import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/download_models.dart';

const _defaultApiBaseUrl = 'https://duck-downloader-production.up.railway.app';

class DuckApiClient {
  DuckApiClient({Dio? dio, String? apiBaseUrl})
    : apiBaseUrl =
          apiBaseUrl ??
          const String.fromEnvironment(
            'DUCK_API_BASE_URL',
            defaultValue: _defaultApiBaseUrl,
          ),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl:
                  apiBaseUrl ??
                  const String.fromEnvironment(
                    'DUCK_API_BASE_URL',
                    defaultValue: _defaultApiBaseUrl,
                  ),
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(minutes: 10),
            ),
          );

  final String apiBaseUrl;
  final Dio _dio;

  Future<MediaMetadata> extract(String url) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/extract',
        data: {'url': url},
      );
      return MediaMetadata.fromJson(url, response.data ?? const {});
    } on DioException catch (error) {
      throw Exception(_readApiError(error));
    }
  }

  Future<String> startDownload({
    required String url,
    required DownloadType type,
    required String quality,
    bool removeMusic = false,
    bool premiumNoWatermark = true,
  }) async {
    try {
      final data = {
        'url': url,
        'type': type.name,
        'quality': quality,
        'removeMusic': removeMusic,
        'premiumNoWatermark': premiumNoWatermark,
      };
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/download',
        data: data,
      );
      final id = response.data?['downloadId']?.toString();
      if (id == null || id.isEmpty) {
        throw StateError('Backend did not return a download id.');
      }
      return id;
    } on DioException catch (error) {
      throw Exception(_readApiError(error));
    }
  }

  Future<DownloadStatusUpdate> controlDownload({
    required String id,
    required String action,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/download/$id/$action',
      );
      return DownloadStatusUpdate.fromJson(response.data ?? const {});
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        throw Exception('Restart backend with latest build, then try again.');
      }
      throw Exception(_readApiError(error));
    }
  }

  Stream<DownloadStatusUpdate> watchDownload(String id) {
    final url = Uri.parse(apiBaseUrl);
    final wsUrl = url.replace(
      scheme: url.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws/download/$id',
      query: '',
    );
    final channel = WebSocketChannel.connect(wsUrl);
    return channel.stream.map((event) {
      try {
        final decoded = event is Map<String, dynamic>
            ? event
            : jsonDecode(event.toString());
        if (decoded is! Map) {
          return const DownloadStatusUpdate(
            progress: 0,
            status: DownloadStatus.failed,
            error: 'Download server returned an unreadable update.',
          );
        }
        return DownloadStatusUpdate.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      } catch (_) {
        return const DownloadStatusUpdate(
          progress: 0,
          status: DownloadStatus.failed,
          error: 'Download server returned an invalid update.',
        );
      }
    });
  }

  String absoluteFileUrl(String value) {
    if (value.startsWith('http')) return value;
    return '$apiBaseUrl$value';
  }

  Future<PlaylistExtractResponse> extractPlaylist(String url) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/playlist/extract',
        data: {'url': url},
      );
      return PlaylistExtractResponse.fromJson(response.data ?? const {});
    } on DioException catch (error) {
      throw Exception(_readApiError(error));
    }
  }

  Future<Map<String, dynamic>> trim({
    required String downloadId,
    required double startTime,
    required double endTime,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/trim',
        data: {
          'downloadId': downloadId,
          'startTime': startTime,
          'endTime': endTime,
        },
      );
      return response.data ?? const {};
    } on DioException catch (error) {
      throw Exception(_readApiError(error));
    }
  }

  String _readApiError(DioException error) {
    final data = error.response?.data;
    if (data is Map && data['detail'] != null) {
      return _fallbackError(data['detail'].toString());
    }
    if (data is String && data.trim().isNotEmpty) return data.trim();
    if (error.type == DioExceptionType.connectionError) {
      return 'Connection to download server failed.';
    }
    return _fallbackError(error.message);
  }

  String _fallbackError(String? value) {
    final cleaned = value?.trim();
    if (cleaned == null || cleaned.isEmpty || cleaned == 'null') {
      return 'Request failed. Check the backend logs and try again.';
    }
    return cleaned;
  }

  Future<BackendCookiesInfo> getCookies() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/api/cookies');
      return BackendCookiesInfo.fromJson(response.data ?? const {});
    } on DioException catch (error) {
      throw Exception(_readApiError(error));
    }
  }

  Future<BackendCookiesInfo> setCookies(String content) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/cookies',
        data: {'cookies': content},
      );
      return BackendCookiesInfo.fromJson(response.data ?? const {});
    } on DioException catch (error) {
      throw Exception(_readApiError(error));
    }
  }

  Future<BackendCookiesInfo> deleteCookies() async {
    try {
      final response = await _dio.delete<Map<String, dynamic>>('/api/cookies');
      return BackendCookiesInfo.fromJson(response.data ?? const {});
    } on DioException catch (error) {
      throw Exception(_readApiError(error));
    }
  }
}
