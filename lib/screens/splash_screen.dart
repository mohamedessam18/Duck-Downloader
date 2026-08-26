import 'dart:async';

import 'package:flutter/material.dart';

import '../constants/asset_paths.dart';
import '../services/ad_service.dart';
import '../state/downloads_controller.dart';
import '../theme/duck_theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/duck_mark.dart';
import '../widgets/duck_sprite_player.dart';
import 'duck_app_screen.dart';
import '../services/crash_reporting_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.controller});
  final DuckDownloadsController controller;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _logoController;
  late AnimationController _rippleController;
  late AnimationController _titleController;
  late Animation<double> _logoScale;
  late Animation<double> _logoFade;
  late Animation<double> _ripple;
  late Animation<double> _titleFade;

  double _initProgress = 0;
  bool _audioReady = false;
  bool _navigated = false;
  final _startedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _titleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    _logoScale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOutBack),
    );
    _logoFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeIn),
    );
    _ripple = Tween<double>(begin: 0.85, end: 1.35).animate(
      CurvedAnimation(parent: _rippleController, curve: Curves.easeOut),
    );
    _titleFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _titleController, curve: Curves.easeOut),
    );

    _logoController.forward();
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _titleController.forward();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_bootstrap());
    });
  }

  Future<void> _bootstrap() async {
    try {
      setState(() => _initProgress = 0.35);
      await widget.controller.markAudioBackgroundReady();
      if (mounted) {
        setState(() {
          _audioReady = true;
          _initProgress = 1.0;
        });
      }
    } catch (error, stackTrace) {
      reportError(error, stackTrace, reason: 'bootstrap');
      if (mounted) setState(() => _initProgress = 1.0);
    } finally {
      await _maybeNavigate();
    }
  }

  Future<void> _maybeNavigate() async {
    if (_navigated || !mounted) return;
    final elapsed = DateTime.now().difference(_startedAt);
    const minSplash = Duration(milliseconds: 2500);
    if (elapsed < minSplash) {
      await Future<void>.delayed(minSplash - elapsed);
    }
    if (!mounted || _navigated) return;
    _navigated = true;

    if (widget.controller.showAdOnOpen) {
      widget.controller.showAdOnOpen = false;
      AdService.instance.showInterstitialAd(
        isPremiumActive: widget.controller.isPremiumActive,
        onAdClosed: () {},
      );
    }

    await Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            DuckAppScreen(controller: widget.controller),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              )),
              child: child,
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 550),
      ),
    );
  }

  @override
  void dispose() {
    _logoController.dispose();
    _rippleController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DuckColors.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Scaffold(
      backgroundColor: colors.background,
      body: AmbientBackground(
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              AnimatedBuilder(
                animation: Listenable.merge([
                  _logoController,
                  _rippleController,
                ]),
                builder: (context, child) {
                  return Opacity(
                    opacity: _logoFade.value,
                    child: Transform.scale(
                      scale: _logoScale.value,
                      child: child,
                    ),
                  );
                },
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (!reduceMotion)
                      ...List.generate(3, (index) {
                        final scale =
                            _ripple.value + index * 0.08;
                        return Transform.scale(
                          scale: scale,
                          child: Container(
                            width: 160,
                            height: 160,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: colors.gold.withValues(
                                  alpha: 0.12 - index * 0.03,
                                ),
                                width: 2,
                              ),
                            ),
                          ),
                        );
                      }),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(36),
                      child: Image.asset(
                        DuckAssets.logoSplash,
                        width: 140,
                        height: 140,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => DuckMark(size: 140),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              if (!reduceMotion)
                DuckSpritePlayer(
                  sprite: DuckAssets.duckLoadingSprite(),
                  size: 72,
                ),
              const SizedBox(height: 20),
              FadeTransition(
                opacity: _titleFade,
                child: Column(
                  children: [
                    ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (bounds) => LinearGradient(
                        colors: [colors.gold, colors.warmGold, colors.gold],
                      ).createShader(bounds),
                      child: const Text(
                        'DUCK DOWNLOADER',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'COPY · DETECT · DOWNLOAD',
                      style: TextStyle(
                        color: colors.textMuted.withValues(alpha: 0.9),
                        fontSize: 11,
                        letterSpacing: 5,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(flex: 2),
              Padding(
                padding: const EdgeInsets.fromLTRB(48, 0, 48, 28),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: _initProgress.clamp(0.05, 1.0),
                        minHeight: 4,
                        backgroundColor: colors.divider,
                        color: colors.gold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _audioReady ? 'Ready' : 'Warming up audio...',
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 12,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
