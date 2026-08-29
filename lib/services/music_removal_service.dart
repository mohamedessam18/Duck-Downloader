import 'dart:async';

import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter/foundation.dart';

import 'ad_service.dart';
import 'premium_entitlement.dart';

/// Why a music-removal request cannot go ahead.
enum MusicRemovalBlock {
  /// The file is longer than this user's tier allows.
  tooLong,

  /// The user was offered the ads and did not finish them.
  adsNotWatched,

  /// No ad could be shown at all — empty inventory, or no network.
  ///
  /// Kept apart from [adsNotWatched] because it is not the user's doing, and
  /// telling someone they "skipped" an ad that never appeared is a lie they
  /// cannot act on.
  adsUnavailable,
}

/// The verdict on one request, before any work is sent to the backend.
class MusicRemovalDecision {
  const MusicRemovalDecision.allowed()
    : isAllowed = true,
      block = null;

  const MusicRemovalDecision.blocked(this.block) : isAllowed = false;

  final bool isAllowed;
  final MusicRemovalBlock? block;
}

/// The rules around removing music, in one place.
///
/// The separation itself happens on the backend — a Demucs worker with a GPU.
/// What lives here is everything the app decides before it asks for that:
/// whether this user may run it at all, how long a file they are allowed, and
/// whether they have paid for this run with ads.
class MusicRemovalService {
  MusicRemovalService({AdService? ads}) : _ads = ads ?? AdService.instance;

  final AdService _ads;

  /// How many rewarded ads a free run costs.
  ///
  /// Two rather than one because a single ad is barely a decision, and the
  /// point of the gate is that the subscription is visibly the easier path.
  /// It is also roughly the length the ads add up to that was wanted — the
  /// SDK has no way to ask for a longer ad, so the only lever is how many.
  static const freeRunAdCount = 2;

  /// The longest file a free run may process.
  ///
  /// Separation cost scales with duration, and two rewarded ads in a
  /// low-eCPM market do not cover a long video. Fifteen minutes is what the
  /// worker itself allows; five is what an ad-funded run pays for.
  static const freeMaxDuration = Duration(minutes: 5);

  /// The longest file the worker will accept from anyone.
  ///
  /// Mirrors `DUCK_MAX_DURATION_SECONDS` in the process worker. Checked here
  /// so an over-long file is refused before it is uploaded and before anyone
  /// watches an ad for a job that was always going to be rejected.
  static const studioMaxDuration = Duration(minutes: 15);

  Duration maxDurationFor({required bool hasStudio}) =>
      hasStudio ? studioMaxDuration : freeMaxDuration;

  /// Whether this entitlement covers music removal without ads.
  bool hasStudio(PremiumEntitlement entitlement) =>
      entitlement.allows(PremiumFeature.musicRemoval);

  /// Checks the length before anything is asked of the user.
  MusicRemovalDecision checkDuration({
    required Duration? duration,
    required bool hasStudio,
  }) {
    // An unknown duration is not a reason to refuse: plenty of downloads
    // never report one, and the worker enforces its own ceiling anyway.
    if (duration == null) return const MusicRemovalDecision.allowed();
    if (duration > maxDurationFor(hasStudio: hasStudio)) {
      return const MusicRemovalDecision.blocked(MusicRemovalBlock.tooLong);
    }
    return const MusicRemovalDecision.allowed();
  }

  /// Collects the ads a free run costs.
  ///
  /// Stops at the first ad the user does not finish; there is no partial
  /// credit, and no reason to show the second ad to someone who closed the
  /// first. Studio subscribers never reach this.
  Future<MusicRemovalDecision> collectPayment({
    required PremiumEntitlement entitlement,
    void Function(int watched, int total)? onProgress,
  }) async {
    if (hasStudio(entitlement)) return const MusicRemovalDecision.allowed();

    for (var i = 0; i < freeRunAdCount; i++) {
      if (!_ads.isRewardedReady) {
        _ads.preloadRewarded();
        // Give a cold start one short chance rather than failing instantly on
        // the first run after launch.
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (!_ads.isRewardedReady) {
        return const MusicRemovalDecision.blocked(
          MusicRemovalBlock.adsUnavailable,
        );
      }

      final earned = await _ads.showRewardedAd();
      if (!earned) {
        return const MusicRemovalDecision.blocked(
          MusicRemovalBlock.adsNotWatched,
        );
      }
      onProgress?.call(i + 1, freeRunAdCount);
    }
    return const MusicRemovalDecision.allowed();
  }

  /// Warms an ad up so the gate does not open onto a spinner.
  void prepare(PremiumEntitlement entitlement) {
    if (hasStudio(entitlement)) return;
    _ads.preloadRewarded();
  }

  /// How long a local file runs for, or null if it cannot be read.
  ///
  /// Uses ffprobe rather than decoding the file: this runs before the user has
  /// agreed to anything, and a length check that itself takes ten seconds on a
  /// long video is worse than no check.
  Future<Duration?> durationOf(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final seconds = session.getMediaInformation()?.getDuration();
      if (seconds == null) return null;
      final value = double.tryParse(seconds);
      if (value == null || value <= 0) return null;
      return Duration(milliseconds: (value * 1000).round());
    } catch (error) {
      // An unreadable length is treated as unknown, not as a refusal — the
      // worker enforces its own ceiling regardless.
      debugPrint('Could not read duration for music removal: $error');
      return null;
    }
  }

  /// Reads the duration the extractor reported.
  ///
  /// The backend sends it as text and the shape varies by source: bare seconds
  /// from one extractor, `mm:ss` or `hh:mm:ss` from another.
  static Duration? parseDuration(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;

    final seconds = double.tryParse(text);
    if (seconds != null) {
      if (seconds <= 0) return null;
      return Duration(milliseconds: (seconds * 1000).round());
    }

    final parts = text.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final numbers = <int>[];
    for (final part in parts) {
      final n = int.tryParse(part.split('.').first.trim());
      if (n == null || n < 0) return null;
      numbers.add(n);
    }
    final hours = numbers.length == 3 ? numbers[0] : 0;
    final minutes = numbers[numbers.length - 2];
    final secs = numbers.last;
    final total = Duration(hours: hours, minutes: minutes, seconds: secs);
    return total > Duration.zero ? total : null;
  }

  /// The status key describing why a request was refused.
  String messageKeyFor(MusicRemovalBlock block, {required bool hasStudio}) {
    switch (block) {
      case MusicRemovalBlock.tooLong:
        return hasStudio
            ? 'musicRemovalTooLongStudio'
            : 'musicRemovalTooLongFree';
      case MusicRemovalBlock.adsNotWatched:
        return 'musicRemovalAdsNotWatched';
      case MusicRemovalBlock.adsUnavailable:
        return 'musicRemovalAdsUnavailable';
    }
  }

  @visibleForTesting
  AdService get ads => _ads;
}
