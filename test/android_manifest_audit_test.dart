import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Locks in the permission set the app actually depends on.
///
/// The READ_MEDIA_* permissions were stripped at one point to keep a Play
/// Console declaration off the listing, which silently broke the in-app media
/// folders browser: on Android 13+ a runtime request for a permission that is
/// absent from the merged manifest is auto-denied, so the library just
/// appeared empty with no way for the user to fix it.
void main() {
  late String manifest;

  setUpAll(() {
    final file = File('android/app/src/main/AndroidManifest.xml');
    expect(file.existsSync(), isTrue, reason: 'AndroidManifest.xml is missing');
    manifest = file.readAsStringSync();
  });

  bool declares(String permission) {
    return manifest.contains('android.permission.$permission"') &&
        !manifest.contains(
          'android.permission.$permission" tools:node="remove"',
        );
  }

  group('media library access', () {
    test('declares read access for every media type the browser lists', () {
      // Android 13+ splits READ_EXTERNAL_STORAGE into one permission per type.
      // Missing any one of them hides that whole category from the browser.
      expect(declares('READ_MEDIA_IMAGES'), isTrue);
      expect(declares('READ_MEDIA_VIDEO'), isTrue);
      expect(declares('READ_MEDIA_AUDIO'), isTrue);
    });

    test('handles Android 14 partial photo access', () {
      // Without this, choosing "Select photos…" is reported as a flat denial.
      expect(declares('READ_MEDIA_VISUAL_USER_SELECTED'), isTrue);
    });

    test('caps the legacy storage permissions at their final API level', () {
      // Scoped storage supersedes both; leaving them uncapped makes Play
      // Console demand justification for permissions newer devices ignore.
      expect(
        manifest.contains(
          'android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"',
        ),
        isTrue,
      );
      expect(
        manifest.contains(
          'android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"',
        ),
        isTrue,
      );
    });
  });

  group('permissions the app must never request', () {
    test('does not ask for microphone access', () {
      // The camera component pulls RECORD_AUDIO in transitively; Duck only
      // takes stills for the vault intruder log.
      expect(
        manifest.contains(
          'android.permission.RECORD_AUDIO" tools:node="remove"',
        ),
        isTrue,
      );
    });

    test('does not ask for location', () {
      expect(declares('ACCESS_FINE_LOCATION'), isFalse);
      expect(declares('ACCESS_COARSE_LOCATION'), isFalse);
    });
  });
}
