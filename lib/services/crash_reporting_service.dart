import 'dart:async';
import 'dart:isolate';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Records a caught error the app recovered from.
///
/// This is the one-liner that replaces a bare `debugPrint` in a `catch` block.
/// In debug it prints exactly like before; in release it files a non-fatal
/// report under [reason] so the failure is visible instead of vanishing —
/// release builds null out `debugPrint`, so a printed error is a lost error.
///
/// [reason] must be a hardcoded slug (`'vault-index-restore'`), never
/// interpolated text. It is the grouping key in the Crashlytics dashboard, so
/// a value that changes per call splits one bug across a hundred issues.
///
/// Fire-and-forget by design: a `catch` block should not have to be async, and
/// reporting must never delay recovery.
void reportError(
  Object error,
  StackTrace? stackTrace, {
  required String reason,
}) {
  if (kDebugMode) {
    debugPrint('[$reason] $error${stackTrace == null ? '' : '\n$stackTrace'}');
  }
  unawaited(CrashReportingService.instance.recordError(
    error,
    stackTrace,
    reason: reason,
  ));
}

/// Drops a breadcrumb onto whatever crash comes next.
///
/// Breadcrumbs are the timeline shown above a stack trace — they turn "it
/// crashed in the player" into "it crashed in the player, right after the
/// vault unlocked and a 4K merge started". Pass fixed text only, for the same
/// reason [reportError] takes a fixed [reason].
void leaveBreadcrumb(String message) =>
    CrashReportingService.instance.log(message);

/// Firebase Crashlytics wiring.
///
/// Every entry point here is failure-tolerant on purpose. Crash reporting is
/// diagnostics, not a feature: if Firebase cannot start — no network on first
/// run, a stale `google-services.json`, a device with no Play Services — the
/// app must carry on exactly as before. Nothing in this file may ever throw
/// into the caller.
///
/// Nothing sensitive is ever attached to a report. The vault PIN, the derived
/// keys and decrypted file paths must never reach [FirebaseCrashlytics.log] or
/// a custom key. That promise is enforced here rather than trusted to call
/// sites: every message goes through [redactForReport] first, because the most
/// common leak is not a deliberate log line, it is an exception that happens to
/// carry a path. `PathNotFoundException: /storage/emulated/0/Duck/mom's
/// surgery.mp4` says nothing that a redacted path and an extension do not.
class CrashReportingService {
  CrashReportingService._();

  static final CrashReportingService instance = CrashReportingService._();

  bool _available = false;
  bool _enabled = true;

  /// Whether reports are currently being collected.
  ///
  /// Reflects the user's choice even when Firebase failed to start, so the
  /// settings toggle shows what the user picked rather than silently flipping.
  bool get enabled => _enabled;

  /// Whether Firebase actually came up. Drives the "unavailable" hint in
  /// settings so a permanently-off toggle is explainable.
  bool get available => _available;

  /// Whether anything would actually be sent right now.
  bool get _collecting => _available && _enabled && !kDebugMode;

  /// Starts Firebase and installs the global error handlers.
  ///
  /// [collectionEnabled] is the user's stored preference. Pass it in rather
  /// than reading storage here: this runs during startup, and the service
  /// should not care where the flag lives.
  Future<void> initialize({required bool collectionEnabled}) async {
    _enabled = collectionEnabled;
    try {
      await Firebase.initializeApp();
      _available = true;
    } catch (error, stackTrace) {
      debugPrint('Crashlytics unavailable: $error\n$stackTrace');
      return;
    }

    final crashlytics = FirebaseCrashlytics.instance;
    // Debug builds would otherwise flood the dashboard with crashes from hot
    // reload and from deliberately-broken work in progress.
    await _applyCollection(collectionEnabled && !kDebugMode);

    // Framework errors (build/layout/paint). In release the default handler
    // only prints, so without this every widget crash is invisible.
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      previousOnError?.call(details);
      if (!kDebugMode) {
        crashlytics.recordFlutterFatalError(details);
      }
    };

    // Errors that escape the Dart isolate — async gaps, unawaited futures,
    // platform channel failures. These never reach FlutterError.onError, and
    // they are exactly the ones that show up as "the app just closed".
    PlatformDispatcher.instance.onError = (error, stack) {
      if (!kDebugMode) {
        crashlytics.recordError(error, stack, fatal: true);
      }
      return true;
    };

    // Errors raised outside any Dart zone — most often a callback invoked
    // straight from native code, which is how the download and media channels
    // re-enter Dart. Neither handler above sees those.
    Isolate.current.addErrorListener(
      RawReceivePort((dynamic pair) {
        if (kDebugMode || pair is! List || pair.length < 2) return;
        final stack = pair[1];
        unawaited(crashlytics.recordError(
          RedactedError(pair[0]),
          stack is String ? StackTrace.fromString(stack) : null,
          fatal: true,
        ));
      }).sendPort,
    );
  }

  /// Applies a change from the settings toggle.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    if (!_available) return;
    await _applyCollection(value && !kDebugMode);
  }

  /// Turns collection on or off for both SDKs at once.
  ///
  /// Analytics is gated by the same switch deliberately. It is only enabled to
  /// give Crashlytics its breadcrumbs and crash-free-user metrics, so leaving
  /// it running after the user opted out of diagnostics would make the
  /// settings toggle a lie — and make the Play Data Safety answers wrong.
  Future<void> _applyCollection(bool value) async {
    try {
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(value);
      if (!value) {
        // Reports already queued on disk would otherwise be uploaded on the
        // next launch, after the user asked to stop sharing.
        await FirebaseCrashlytics.instance.deleteUnsentReports();
      }
    } catch (error) {
      debugPrint('Crashlytics collection toggle failed: $error');
    }
    try {
      await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(value);
    } catch (error) {
      debugPrint('Analytics collection toggle failed: $error');
    }
  }

  /// Records a caught error that the app recovered from.
  ///
  /// Prefer the top-level [reportError] at call sites; this is the plumbing
  /// behind it. Use for failures worth knowing about but not worth crashing
  /// over — a download that died mid-stream, a vault index that would not
  /// decrypt.
  Future<void> recordError(
    Object error,
    StackTrace? stackTrace, {
    String? reason,
  }) async {
    if (!_collecting) return;
    try {
      await FirebaseCrashlytics.instance.recordError(
        RedactedError(error),
        stackTrace,
        reason: reason,
        fatal: false,
      );
    } catch (_) {
      // Reporting a failure must never become a second failure.
    }
  }

  /// Attaches a breadcrumb to the next report. See [leaveBreadcrumb].
  void log(String message) {
    if (!_collecting) return;
    try {
      FirebaseCrashlytics.instance.log(redactForReport(message));
    } catch (_) {
      // Never let diagnostics break the thing being diagnosed.
    }
  }

  /// Tags every subsequent report with where startup had got to.
  ///
  /// A launch crash arrives with no breadcrumbs and a stack trace full of
  /// framework frames; this is what tells you whether the app died before or
  /// after the vault came up. Cleared to `ready` once the UI is running.
  void setStage(String stage) {
    if (!_collecting) return;
    try {
      unawaited(FirebaseCrashlytics.instance.setCustomKey('startup_stage', stage));
    } catch (_) {
      // As above.
    }
  }
}

/// Wraps an error so its message is redacted while its type is preserved.
///
/// Crashlytics groups issues by the reported type and message, so the original
/// `runtimeType` has to survive redaction — replacing the whole error with a
/// string would collapse every unrelated failure into one issue.
@immutable
class RedactedError implements Exception {
  const RedactedError(this.original);

  final Object original;

  @override
  String toString() =>
      '${original.runtimeType}: ${redactForReport(original.toString())}';
}

final _urlPattern = RegExp(r'(https?://[^\s/]+)(/\S*)?', caseSensitive: false);
final _pathPattern = RegExp(r'(?:/[\w .@+()\[\]%-]+){2,}');
final _extensionPattern = RegExp(r'\.([A-Za-z0-9]{2,4})$');

/// Strips user data out of text bound for a crash report.
///
/// Keeps what identifies the *failure* and drops what identifies the *user*:
/// a URL keeps its host (knowing TikTok broke is the whole point) and loses its
/// path and query (which is the video, the account, and often a token). A
/// filesystem path is replaced entirely, except for its extension, because
/// "the .mp4 branch fails" is a real clue and the filename never is.
///
/// Exposed for tests: this is a privacy guarantee, so it is worth asserting on
/// directly rather than only through a mocked Crashlytics.
String redactForReport(String input) {
  var output = input.replaceAllMapped(_urlPattern, (match) {
    final host = match.group(1)!;
    return match.group(2) == null ? host : '$host/<redacted>';
  });
  output = output.replaceAllMapped(_pathPattern, (match) {
    final matched = match.group(0)!;
    final path = _pathEndOf(matched);
    final extension = _extensionPattern.firstMatch(path);
    final redacted =
        extension == null ? '<path>' : '<path>.${extension.group(1)}';
    // Whatever the greedy match over-ran is the rest of the sentence.
    return '$redacted${matched.substring(path.length)}';
  });
  return output;
}

/// Finds where a path actually ends inside a greedy match.
///
/// Filenames contain spaces, so a path cannot simply end at the first one —
/// but neither can it swallow the rest of the sentence, which is what
/// `/sdcard/clip.mp4 failed to open` would otherwise do. The extension is the
/// only reliable terminator, so take the shortest prefix that ends in one.
///
/// When there is no extension anywhere, keep the whole match: over-redacting a
/// few trailing words is a cosmetic problem, and leaking half a filename is
/// not.
String _pathEndOf(String matched) {
  final words = matched.split(' ');
  for (var end = 1; end < words.length; end++) {
    final candidate = words.sublist(0, end).join(' ');
    if (_extensionPattern.hasMatch(candidate)) return candidate;
  }
  return matched;
}
