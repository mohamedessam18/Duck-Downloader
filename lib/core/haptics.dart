import 'package:flutter/services.dart';

/// Central place for tactile feedback so the whole app speaks one language:
/// selection for navigation, light for ordinary taps, medium for a completed
/// job, heavy for a failure.
///
/// Every call is fire-and-forget and swallows platform errors — a device
/// without a taptic engine (or with system haptics turned off) must never turn
/// a UI interaction into an exception.
class DuckHaptics {
  DuckHaptics._();

  /// Moving between tabs, dragging the nav pill onto a new segment, switching
  /// a sub-filter. The lightest possible tick.
  static void selection() => _run(HapticFeedback.selectionClick);

  /// A normal button, row or card press.
  static void tap() => _run(HapticFeedback.lightImpact);

  /// A toggle flipping, a sheet committing a choice.
  static void toggle() => _run(HapticFeedback.selectionClick);

  /// A download finished, a file was saved, a conversion completed.
  static void success() => _run(HapticFeedback.mediumImpact);

  /// A download failed, a PIN was wrong, an action was rejected.
  static void error() => _run(HapticFeedback.heavyImpact);

  /// Long-press revealing a menu or entering a drag.
  static void longPress() => _run(HapticFeedback.mediumImpact);

  static void _run(Future<void> Function() action) {
    try {
      action();
    } catch (_) {
      // No haptics hardware, or the platform channel is unavailable.
    }
  }
}
