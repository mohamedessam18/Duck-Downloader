import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

class AdService {
  AdService._privateConstructor();

  static final AdService instance = AdService._privateConstructor();

  // Flag to toggle between Test Ads and Real AdMob Ads
  // Set this to false for your final Google Play Store release!
  static const bool useTestAds = true;

  // Real AdMob Unit IDs (Android)
  static const String _realBannerUnitId = 'ca-app-pub-8105551932366170/7864063590';
  static const String _realInterstitialUnitId = 'ca-app-pub-8105551932366170/3705326736';

  // Google Test Ad Unit IDs (Android)
  static const String _testBannerUnitId = 'ca-app-pub-3940256099942544/6300978111';
  static const String _testInterstitialUnitId = 'ca-app-pub-3940256099942544/1033173712';

  // Getter for current Banner Ad Unit ID based on mode
  String get bannerAdUnitId {
    if (useTestAds || kDebugMode) {
      return _testBannerUnitId;
    }
    return _realBannerUnitId;
  }

  // Getter for current Interstitial Ad Unit ID based on mode
  String get interstitialAdUnitId {
    if (useTestAds || kDebugMode) {
      return _testInterstitialUnitId;
    }
    return _realInterstitialUnitId;
  }

  // Cooldown timer variables for Interstitial Ads (5-minute frequency capping)
  DateTime? _lastInterstitialShowTime;
  static const Duration _interstitialCooldown = Duration(minutes: 5);

  // Active Interstitial Ad reference
  InterstitialAd? _interstitialAd;
  bool _isInterstitialLoading = false;

  /// Initializes the Google Mobile Ads SDK
  Future<void> initialize() async {
    await MobileAds.instance.initialize();
  }

  /// Helper to check if the cooldown period has elapsed since the last ad
  bool get _isCooldownElapsed {
    if (_lastInterstitialShowTime == null) return true;
    final elapsed = DateTime.now().difference(_lastInterstitialShowTime!);
    return elapsed >= _interstitialCooldown;
  }

  /// Loads and shows an Interstitial Ad overlay
  /// Runs [onAdClosed] immediately if the user is Premium, the cooldown is active, or loading fails.
  void showInterstitialAd({
    required bool isPremiumActive,
    required VoidCallback onAdClosed,
  }) {
    // 1. If user is Premium/Pro, bypass ads completely
    if (isPremiumActive) {
      onAdClosed();
      return;
    }

    // 2. If the 5-minute cooldown has not elapsed yet, bypass
    if (!_isCooldownElapsed) {
      debugPrint("AdMob: Interstitial cooldown is active. Bypassing ad.");
      onAdClosed();
      return;
    }

    // 3. Avoid double loading
    if (_isInterstitialLoading) {
      onAdClosed();
      return;
    }

    _isInterstitialLoading = true;
    debugPrint("AdMob: Loading Interstitial Ad using Unit ID: $interstitialAdUnitId");

    InterstitialAd.load(
      adUnitId: interstitialAdUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (InterstitialAd ad) {
          _interstitialAd = ad;
          _isInterstitialLoading = false;
          _lastInterstitialShowTime = DateTime.now(); // Reset cooldown timer

          // Define full-screen callbacks
          _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (InterstitialAd ad) {
              debugPrint("AdMob: Interstitial ad dismissed.");
              ad.dispose();
              onAdClosed(); // Proceed with download screen navigation
            },
            onAdFailedToShowFullScreenContent: (InterstitialAd ad, AdError error) {
              debugPrint("AdMob: Interstitial failed to show: $error");
              ad.dispose();
              onAdClosed();
            },
          );

          // Show the ad
          _interstitialAd!.show();
        },
        onAdFailedToLoad: (LoadAdError error) {
          debugPrint("AdMob: Interstitial failed to load: $error");
          _isInterstitialLoading = false;
          onAdClosed(); // Fallback safely so download flows continue
        },
      ),
    );
  }

  /// Creates and loads a new Banner Ad instance
  BannerAd createBannerAd({
    required bool isPremiumActive,
    required VoidCallback onAdLoaded,
    required Function(LoadAdError) onAdFailedToLoad,
  }) {
    return BannerAd(
      adUnitId: bannerAdUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          debugPrint("AdMob: Banner Ad loaded successfully.");
          onAdLoaded();
        },
        onAdFailedToLoad: (ad, error) {
          debugPrint("AdMob: Banner Ad failed to load: $error");
          ad.dispose();
          onAdFailedToLoad(error);
        },
      ),
    );
  }
}
