import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import '../services/ad_service.dart';

class AdMobBannerWidget extends StatefulWidget {
  const AdMobBannerWidget({super.key, required this.isPremiumActive});

  final bool isPremiumActive;

  @override
  State<AdMobBannerWidget> createState() => _AdMobBannerWidgetState();
}

class _AdMobBannerWidgetState extends State<AdMobBannerWidget> {
  BannerAd? _bannerAd;
  AdSize? _adSize;
  bool _isAdLoaded = false;
  bool _isLoading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bannerAd == null && !widget.isPremiumActive && !_isLoading) {
      _loadAd();
    }
  }

  @override
  void didUpdateWidget(covariant AdMobBannerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If premium status changed, reload or dispose of the ad
    if (widget.isPremiumActive != oldWidget.isPremiumActive) {
      if (widget.isPremiumActive) {
        _disposeAd();
      } else {
        _loadAd();
      }
    }
  }

  void _loadAd() async {
    if (widget.isPremiumActive || _isLoading) return;
    _isLoading = true;

    try {
      // Calculate current orientation anchored adaptive banner size
      final width = MediaQuery.sizeOf(context).width.truncate();
      final AdSize? size = await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width);
      if (size == null) {
        debugPrint("AdMob: Failed to calculate adaptive banner size. Falling back to standard banner.");
        _isLoading = false;
        return;
      }

      if (!mounted) return;
      setState(() {
        _adSize = size;
      });

      _bannerAd = AdService.instance.createBannerAd(
        size: size,
        isPremiumActive: widget.isPremiumActive,
        onAdLoaded: () {
          if (mounted) {
            setState(() {
              _isAdLoaded = true;
              _isLoading = false;
            });
          }
        },
        onAdFailedToLoad: (error) {
          _disposeAd();
        },
      );
      _bannerAd!.load();
    } catch (e) {
      debugPrint("AdMob: Error loading adaptive banner: $e");
      _disposeAd();
    }
  }

  void _disposeAd() {
    _bannerAd?.dispose();
    _bannerAd = null;
    _adSize = null;
    _isAdLoaded = false;
    _isLoading = false;
  }

  @override
  void dispose() {
    _disposeAd();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isPremiumActive || !_isAdLoaded || _bannerAd == null || _adSize == null) {
      return const SizedBox.shrink();
    }

    return Container(
      alignment: Alignment.center,
      width: _adSize!.width.toDouble(),
      height: _adSize!.height.toDouble(),
      margin: const EdgeInsets.only(bottom: 6),
      child: AdWidget(ad: _bannerAd!),
    );
  }
}
