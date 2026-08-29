import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import './crash_reporting_service.dart';

class AdService {
  AdService._privateConstructor();

  static final AdService instance = AdService._privateConstructor();

  /// Whether to serve Google's test units instead of the real ones.
  ///
  /// This used to be a hand-flipped `true`, which meant every store build
  /// shipped test ads — zero revenue, and AdMob treats real traffic on a test
  /// unit as a policy violation. Tying it to the build mode instead makes the
  /// safe thing automatic: debug and profile builds can never request a real
  /// unit (clicking your own live ads gets an account suspended), and release
  /// builds can never accidentally ship a test one.
  ///
  /// Pass `--dart-define=DUCK_TEST_ADS=true` to force test units in a release
  /// build when validating a store track.
  static const bool useTestAds = kReleaseMode
      ? bool.fromEnvironment('DUCK_TEST_ADS')
      : true;

  // Real AdMob Unit IDs (Android)
  static const String _realAndroidBannerUnitId =
      'ca-app-pub-8105551932366170/7864063590';
  static const String _realAndroidInterstitialUnitId =
      'ca-app-pub-8105551932366170/3705326736';

  /// Rewarded unit, for the music-removal gate.
  static const String _realAndroidRewardedUnitId =
      'ca-app-pub-8105551932366170/9835640296';

  // Real AdMob Unit IDs (iOS) — create these in the AdMob console for the iOS
  // app entry and paste them here. While they are empty the iOS build keeps
  // serving Google's test units instead of silently requesting Android units,
  // which AdMob rejects.
  static const String _realIosBannerUnitId = '';
  static const String _realIosInterstitialUnitId = '';
  static const String _realIosRewardedUnitId = '';

  // Google Test Ad Unit IDs
  static const String _testAndroidBannerUnitId =
      'ca-app-pub-3940256099942544/6300978111';
  static const String _testAndroidInterstitialUnitId =
      'ca-app-pub-3940256099942544/1033173712';
  static const String _testIosBannerUnitId =
      'ca-app-pub-3940256099942544/2934735716';
  static const String _testIosInterstitialUnitId =
      'ca-app-pub-3940256099942544/4411468910';
  static const String _testAndroidRewardedUnitId =
      'ca-app-pub-3940256099942544/5224354917';
  static const String _testIosRewardedUnitId =
      'ca-app-pub-3940256099942544/1712485313';

  bool get _isIos => !kIsWeb && Platform.isIOS;

  /// Banner unit for the current platform and mode.
  String get bannerAdUnitId {
    if (useTestAds || kDebugMode) {
      return _isIos ? _testIosBannerUnitId : _testAndroidBannerUnitId;
    }
    if (_isIos) {
      return _realIosBannerUnitId.isEmpty
          ? _testIosBannerUnitId
          : _realIosBannerUnitId;
    }
    return _realAndroidBannerUnitId;
  }

  /// Interstitial unit for the current platform and mode.
  String get interstitialAdUnitId {
    if (useTestAds || kDebugMode) {
      return _isIos ? _testIosInterstitialUnitId : _testAndroidInterstitialUnitId;
    }
    if (_isIos) {
      return _realIosInterstitialUnitId.isEmpty
          ? _testIosInterstitialUnitId
          : _realIosInterstitialUnitId;
    }
    return _realAndroidInterstitialUnitId;
  }

  /// Rewarded unit for the current platform and mode.
  String get rewardedAdUnitId {
    if (useTestAds || kDebugMode) {
      return _isIos ? _testIosRewardedUnitId : _testAndroidRewardedUnitId;
    }
    if (_isIos) {
      return _realIosRewardedUnitId.isEmpty
          ? _testIosRewardedUnitId
          : _realIosRewardedUnitId;
    }
    return _realAndroidRewardedUnitId.isEmpty
        ? _testAndroidRewardedUnitId
        : _realAndroidRewardedUnitId;
  }

  // Frequency capping for Interstitial Ads.
  DateTime? _lastInterstitialShowTime;
  static const Duration _interstitialCooldown = Duration(minutes: 5);

  // Pre-loaded Interstitial Ad, kept warm so showing one is instant.
  InterstitialAd? _interstitialAd;
  bool _isInterstitialLoading = false;
  bool _initialized = false;

  /// Initializes the Google Mobile Ads SDK.
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      await MobileAds.instance.initialize();
      _initialized = true;
      preloadInterstitial();
      preloadRewarded();
    } catch (error, stackTrace) {
      reportError(error, stackTrace, reason: 'admob-init');
    }
  }

  bool get _isCooldownElapsed {
    if (_lastInterstitialShowTime == null) return true;
    final elapsed = DateTime.now().difference(_lastInterstitialShowTime!);
    return elapsed >= _interstitialCooldown;
  }

  /// Fetches an interstitial in the background so the next [showInterstitialAd]
  /// can display it immediately instead of stalling the user's download.
  void preloadInterstitial() {
    if (_interstitialAd != null || _isInterstitialLoading) return;
    _isInterstitialLoading = true;

    InterstitialAd.load(
      adUnitId: interstitialAdUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _isInterstitialLoading = false;
          _interstitialAd = ad;
        },
        onAdFailedToLoad: (error) {
          debugPrint('AdMob: Interstitial failed to load: $error');
          _isInterstitialLoading = false;
          _interstitialAd = null;
        },
      ),
    );
  }

  /// Shows a pre-loaded Interstitial Ad overlay.
  ///
  /// [onAdClosed] runs immediately — and exactly once — if the user is Premium,
  /// the cooldown is still active, or no ad is ready, so download flows are
  /// never blocked waiting on an ad.
  void showInterstitialAd({
    required bool isPremiumActive,
    required VoidCallback onAdClosed,
  }) {
    if (isPremiumActive) {
      onAdClosed();
      return;
    }

    if (!_isCooldownElapsed) {
      debugPrint('AdMob: Interstitial cooldown is active. Bypassing ad.');
      onAdClosed();
      return;
    }

    final ad = _interstitialAd;
    if (ad == null) {
      // Nothing warm to show — start fetching for next time and move on.
      preloadInterstitial();
      onAdClosed();
      return;
    }

    // Hand ownership to the callbacks below so a second call cannot show the
    // same ad twice (which AdMob treats as an invalid impression).
    _interstitialAd = null;

    var proceeded = false;
    void proceedOnce() {
      if (proceeded) return;
      proceeded = true;
      onAdClosed();
    }

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (_) {
        _lastInterstitialShowTime = DateTime.now();
      },
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        preloadInterstitial();
        proceedOnce();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('AdMob: Interstitial failed to show: $error');
        ad.dispose();
        preloadInterstitial();
        proceedOnce();
      },
    );

    try {
      ad.show();
    } catch (error) {
      debugPrint('AdMob: Interstitial show threw: $error');
      ad.dispose();
      proceedOnce();
    }
  }

  // ── Rewarded ads ──────────────────────────────────────────────────────────

  RewardedAd? _rewardedAd;
  bool _isRewardedLoading = false;

  /// Fetches a rewarded ad so the next [showRewardedAd] does not stall.
  void preloadRewarded() {
    if (_rewardedAd != null || _isRewardedLoading) return;
    _isRewardedLoading = true;
    RewardedAd.load(
      adUnitId: rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardedAd = ad;
          _isRewardedLoading = false;
        },
        onAdFailedToLoad: (error) {
          _rewardedAd = null;
          _isRewardedLoading = false;
          debugPrint('AdMob: Rewarded failed to load: $error');
        },
      ),
    );
  }

  /// Shows one rewarded ad and reports whether the user earned the reward.
  ///
  /// Earning is the user's choice and always has been: the SDK gives them a
  /// close button, and closing early forfeits the reward. There is no way to
  /// hold someone in an ad, and no way to ask for a longer one — the length
  /// belongs to the creative, not to us. Trying to force either is a policy
  /// violation, so the gate is built on "did they finish it", not "how long
  /// did we keep them".
  ///
  /// Returns false when no ad could be shown at all, which the caller must
  /// treat as *not* earned — otherwise an empty ad inventory silently becomes
  /// a free pass.
  Future<bool> showRewardedAd() async {
    final ad = _rewardedAd;
    if (ad == null) {
      // Nothing warm. Start fetching for next time and tell the caller now
      // rather than making them wait on a load that may never finish.
      preloadRewarded();
      return false;
    }
    _rewardedAd = null;

    var earned = false;
    final closed = Completer<bool>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        preloadRewarded();
        if (!closed.isCompleted) closed.complete(earned);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        preloadRewarded();
        reportError(error, StackTrace.current, reason: 'admob-rewarded-show');
        if (!closed.isCompleted) closed.complete(false);
      },
    );

    try {
      await ad.show(
        onUserEarnedReward: (_, _) => earned = true,
      );
    } catch (error, stackTrace) {
      reportError(error, stackTrace, reason: 'admob-rewarded');
      if (!closed.isCompleted) closed.complete(false);
    }
    return closed.future;
  }

  /// Whether a rewarded ad is ready to show right now.
  bool get isRewardedReady => _rewardedAd != null;

  /// Creates and loads a new Banner Ad instance
  BannerAd createBannerAd({
    required AdSize size,
    required bool isPremiumActive,
    required VoidCallback onAdLoaded,
    required Function(LoadAdError) onAdFailedToLoad,
  }) {
    return BannerAd(
      adUnitId: bannerAdUnitId,
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          debugPrint('AdMob: Banner Ad loaded successfully.');
          onAdLoaded();
        },
        onAdFailedToLoad: (ad, error) {
          debugPrint('AdMob: Banner Ad failed to load: $error');
          ad.dispose();
          onAdFailedToLoad(error);
        },
      ),
    );
  }
}
