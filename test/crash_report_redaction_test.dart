import 'package:duck_downloader/services/crash_reporting_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The privacy promise in [CrashReportingService] is only worth what it can be
/// held to. Crash reports leave the device, so these are the assertions that
/// keep "we never send your files or your links" true as the app grows.
void main() {
  group('redactForReport', () {
    test('drops the path and query of a URL but keeps the host', () {
      // Which site broke is the diagnosis; which video it was is the user's
      // business — and the query string is where the tokens live.
      expect(
        redactForReport(
          'DioException: failed GET https://www.tiktok.com/@someone/video/12345?token=abc',
        ),
        'DioException: failed GET https://www.tiktok.com/<redacted>',
      );
    });

    test('keeps a bare host untouched', () {
      expect(
        redactForReport('SocketException: no route to https://api.cobalt.tools'),
        'SocketException: no route to https://api.cobalt.tools',
      );
    });

    test('replaces filesystem paths but keeps the extension', () {
      expect(
        redactForReport(
          "PathNotFoundException: /storage/emulated/0/Duck/holiday video.mp4",
        ),
        'PathNotFoundException: <path>.mp4',
      );
    });

    test('redacts vault paths, which are the most sensitive of all', () {
      final redacted = redactForReport(
        'FileSystemException: /data/user/0/com.duck.downloader/vault/private.enc',
      );
      expect(redacted, 'FileSystemException: <path>.enc');
      expect(redacted, isNot(contains('vault')));
    });

    test('handles several secrets in one message', () {
      expect(
        redactForReport('copy /var/mobile/a/b.mp4 from https://x.com/user/status/9'),
        'copy <path>.mp4 from https://x.com/<redacted>',
      );
    });

    test('leaves ordinary error text alone', () {
      // Over-redaction is its own failure: a report that says nothing is as
      // useless as no report.
      const message = 'RangeError: index 5 not in range 0..3';
      expect(redactForReport(message), message);
    });
  });

  group('RedactedError', () {
    test('preserves the original type so Crashlytics can still group', () {
      final error = RedactedError(
        const FileSystemException('failed', '/storage/emulated/0/a/b.mp4'),
      );
      expect(error.toString(), startsWith('FileSystemException:'));
      expect(error.toString(), isNot(contains('b.mp4')));
    });
  });
}

/// Stands in for `dart:io`'s exception so the test stays free of platform I/O.
class FileSystemException implements Exception {
  const FileSystemException(this.message, this.path);

  final String message;
  final String path;

  @override
  String toString() => 'FileSystemException: $message, path = $path';
}
