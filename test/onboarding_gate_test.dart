import 'package:duck_downloader/services/download_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// Minimal in-memory stand-in for a Hive box.
///
/// The real box needs a temp directory and an initialised Hive; the store only
/// ever calls get/put/delete, so a map is enough to pin down the branching.
class _FakeBox extends Fake implements Box<dynamic> {
  _FakeBox([Map<String, dynamic>? seed]) : _data = {...?seed};

  final Map<String, dynamic> _data;

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) {
    return _data.containsKey(key) ? _data[key] : defaultValue;
  }

  @override
  Future<void> put(dynamic key, dynamic value) async {
    _data['$key'] = value;
  }

  @override
  Future<void> delete(dynamic key) async {
    _data.remove('$key');
  }
}

void main() {
  group('onboarding gate', () {
    test('a genuinely fresh install sees the intro', () {
      final store = DownloadStore(_FakeBox());
      expect(store.readOnboardingCompleted(), isFalse);
    });

    test('an upgrading user with downloads skips the intro', () {
      // The flag did not exist before this release, so every existing user
      // reads back null. Without the downloads check they would all be shown
      // a first-run intro on the update.
      // The gate only asks whether the list is non-empty — it never decodes
      // the entries — so an opaque map keeps this test from breaking every
      // time DownloadItem gains a required field.
      final store = DownloadStore(
        _FakeBox({
          'downloads': [
            {'id': '1', 'title': 'A'},
          ],
        }),
      );
      expect(store.readOnboardingCompleted(), isTrue);
    });

    test('an upgrading user with an empty history still sees the intro', () {
      final store = DownloadStore(_FakeBox({'downloads': const []}));
      expect(store.readOnboardingCompleted(), isFalse);
    });

    test('completing the intro is remembered', () async {
      final store = DownloadStore(_FakeBox());
      await store.writeOnboardingCompleted(true);
      expect(store.readOnboardingCompleted(), isTrue);
    });

    test('a corrupt flag falls back to the downloads heuristic', () {
      // Hive is untyped; a value written by an older or broken build must not
      // throw on read.
      final store = DownloadStore(_FakeBox({'onboardingCompleted': 'yes'}));
      expect(store.readOnboardingCompleted(), isFalse);
    });
  });

  group('premium offer hand-off', () {
    test('is not pending by default', () {
      final store = DownloadStore(_FakeBox());
      expect(store.readPendingPremiumOffer(), isFalse);
    });

    test('survives being written and read back', () async {
      final store = DownloadStore(_FakeBox());
      await store.writePendingPremiumOffer(true);
      expect(store.readPendingPremiumOffer(), isTrue);
      await store.writePendingPremiumOffer(false);
      expect(store.readPendingPremiumOffer(), isFalse);
    });
  });

  group('crash reporting preference', () {
    test('defaults to on', () {
      expect(DownloadStore(_FakeBox()).readCrashReportingEnabled(), isTrue);
    });

    test('an explicit opt-out is respected', () async {
      final store = DownloadStore(_FakeBox());
      await store.writeCrashReportingEnabled(false);
      expect(store.readCrashReportingEnabled(), isFalse);
    });
  });
}
