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
  bool _isAdLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadAd();
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

  void _loadAd() {
    if (widget.isPremiumActive) return;

    _bannerAd = AdService.instance.createBannerAd(
      isPremiumActive: widget.isPremiumActive,
      onAdLoaded: () {
        if (mounted) {
          setState(() {
            _isAdLoaded = true;
          });
        }
      },
      onAdFailedToLoad: (error) {
        _disposeAd();
      },
    );
    _bannerAd!.load();
  }

  void _disposeAd() {
    _bannerAd?.dispose();
    _bannerAd = null;
    _isAdLoaded = false;
  }

  @override
  void dispose() {
    _disposeAd();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isPremiumActive || !_isAdLoaded || _bannerAd == null) {
      return const SizedBox.shrink();
    }

    return Container(
      alignment: Alignment.center,
      width: _bannerAd!.size.width.toDouble(),
      height: _bannerAd!.size.height.toDouble(),
      margin: const EdgeInsets.only(bottom: 6),
      child: AdWidget(ad: _bannerAd!),
    );
  }
}
