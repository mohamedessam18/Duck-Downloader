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

  // Real AdMob Unit IDs (iOS) — create these in the AdMob console for the iOS
  // app entry and paste them here. While they are empty the iOS build keeps
  // serving Google's test units instead of silently requesting Android units,
  // which AdMob rejects.
  static const String _realIosBannerUnitId = '';
  static const String _realIosInterstitialUnitId = '';

  // Google Test Ad Unit IDs
  static const String _testAndroidBannerUnitId =
      'ca-app-pub-3940256099942544/6300978111';
  static const String _testAndroidInterstitialUnitId =
      'ca-app-pub-3940256099942544/1033173712';
  static const String _testIosBannerUnitId =
      'ca-app-pub-3940256099942544/2934735716';
  static const String _testIosInterstitialUnitId =
      'ca-app-pub-3940256099942544/4411468910';

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
