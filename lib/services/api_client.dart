import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/download_models.dart';

class DuckApiClient {
  DuckApiClient({Dio? dio, String? apiBaseUrl})
    : apiBaseUrl =
          apiBaseUrl ??
          const String.fromEnvironment(
            'DUCK_API_BASE_URL',
            defaultValue: 'http://localhost:8000',
          ),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl:
                  apiBaseUrl ??
                  const String.fromEnvironment(
                    'DUCK_API_BASE_URL',
                    defaultValue: 'http://localhost:8000',
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
    required bool premiumNoWatermark,
    String? licenseKey,
  }) async {
    try {
      final data = {
        'url': url,
        'type': type.name,
        'quality': quality,
        'premiumNoWatermark': premiumNoWatermark,
      };
      if (licenseKey != null) data['licenseKey'] = licenseKey;
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

  Future<bool> activateLicense(String licenseKey) {
    return _checkLicense('/api/license/activate', licenseKey);
  }

  Future<bool> verifyLicense(String licenseKey) {
    return _checkLicense('/api/license/verify', licenseKey);
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
      final payload = event is Map<String, dynamic>
          ? event
          : jsonDecode(event.toString()) as Map<String, dynamic>;
      return DownloadStatusUpdate.fromJson(payload);
    });
  }

  String absoluteFileUrl(String value) {
    if (value.startsWith('http')) return value;
    return '$apiBaseUrl$value';
  }

  Future<bool> _checkLicense(String path, String licenseKey) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        path,
        data: {'licenseKey': licenseKey.trim()},
      );
      return response.data?['active'] == true;
    } on DioException catch (error) {
      throw Exception(_readApiError(error));
    }
  }

  String _readApiError(DioException error) {
    final data = error.response?.data;
    if (data is Map && data['detail'] != null) return data['detail'].toString();
    if (data is String && data.isNotEmpty) return data;
    if (error.type == DioExceptionType.connectionError) {
      return 'Connection to download server failed.';
    }
    return error.message ?? 'Request failed.';
  }
}
