import 'package:duck_downloader/services/trim_service.dart';import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TrimService.validateRange', () {
    test('rejects start >= end', () {
      expect(
        () => TrimService.validateRange(
          startSec: 5,
          endSec: 5,
          totalDuration: const Duration(seconds: 30),
        ),
        throwsA(isA<TrimValidationException>()),
      );
    });

    test('rejects clips shorter than one second', () {
      expect(
        () => TrimService.validateRange(
          startSec: 1,
          endSec: 1.5,
          totalDuration: const Duration(seconds: 30),
        ),
        throwsA(isA<TrimValidationException>()),
      );
    });

    test('accepts valid range', () {
      expect(
        () => TrimService.validateRange(
          startSec: 2,
          endSec: 10,
          totalDuration: const Duration(seconds: 30),
        ),
        returnsNormally,
      );
    });
  });
}
