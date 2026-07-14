import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:liquid_glass_plus/liquid_glass_plus.dart';

/// Duck-themed liquid glass primitives for iOS (Impeller shaders).
class DuckLiquidGlass {
  DuckLiquidGlass._();

  static bool shouldUseLiquidGlass(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.iOS) return false;
    return !MediaQuery.disableAnimationsOf(context);
  }

  static LiquidGlassSettings track({
    required bool isLight,
    bool isDragging = false,
  }) {
    return LiquidGlassSettings(
      thickness: isDragging ? 22 : 15,
      frostIntensity: isLight ? 14 : 12,
      glassColor: isLight ? const Color(0xB8FFFFFF) : const Color(0x14FFFFFF),
      lightIntensity: isDragging ? 1.6 : 1.1,
      ambientStrength: 0.08,
      saturation: 1.15,
      liquidGlassConfigs: LiquidGlassConfigs(
        refractiveIndex: isDragging ? 1.5 : 1.45,
        chromaticAberration: 0.012,
      ),
      animationDuration: const Duration(milliseconds: 200),
      animationCurve: Curves.easeOut,
    );
  }

  static LiquidGlassSettings pill({
    required Color goldColor,
    bool isDragging = false,
  }) {
    return LiquidGlassSettings(
      thickness: isDragging ? 26 : 20,
      frostIntensity: isDragging ? 10 : 8,
      glassColor: goldColor.withValues(alpha: isDragging ? 0.72 : 0.55),
      lightIntensity: isDragging ? 1.8 : 1.4,
      ambientStrength: 0.1,
      saturation: 1.25,
      liquidGlassConfigs: LiquidGlassConfigs(
        refractiveIndex: isDragging ? 1.55 : 1.48,
        chromaticAberration: 0.015,
      ),
      animationDuration: const Duration(milliseconds: 200),
      animationCurve: Curves.easeOutBack,
    );
  }

  static LiquidGlassSettings button({bool isDragging = false}) {
    return LiquidGlassSettings(
      thickness: isDragging ? 24 : 18,
      frostIntensity: isDragging ? 14 : 10,
      glassColor: const Color(0x33FFFFFF),
      lightIntensity: isDragging ? 1.7 : 1.3,
      ambientStrength: 0.06,
      saturation: 1.2,
      liquidGlassConfigs: LiquidGlassConfigs(
        refractiveIndex: isDragging ? 1.5 : 1.45,
        chromaticAberration: 0.01,
      ),
      animationDuration: const Duration(milliseconds: 250),
      animationCurve: Curves.easeOutBack,
    );
  }

  static LiquidGlassSettings panel({required bool isLight}) {
    return LiquidGlassSettings(
      thickness: 16,
      frostIntensity: isLight ? 12 : 10,
      glassColor: isLight ? const Color(0xB8FFFFFF) : const Color(0x0FFFFFFF),
      lightIntensity: 1.0,
      ambientStrength: 0.05,
      saturation: 1.12,
      liquidGlassConfigs: const LiquidGlassConfigs(
        refractiveIndex: 1.42,
        chromaticAberration: 0.008,
      ),
    );
  }

  static LiquidGlassSettings capsule({bool isDragging = false}) {
    return button(isDragging: isDragging).copyWith(
      thickness: isDragging ? 20 : 16,
      frostIntensity: isDragging ? 12 : 10,
    );
  }
}

/// Frosted-glass fallback for Android and reduced-motion mode.
class DuckFrostedSurface extends StatelessWidget {
  const DuckFrostedSurface({
    super.key,
    required this.borderRadius,
    required this.child,
    this.blurSigma = 18,
    this.color,
    this.borderColor,
    this.gradient,
    this.clipOval = false,
  });

  final double borderRadius;
  final Widget child;
  final double blurSigma;
  final Color? color;
  final Color? borderColor;
  final Gradient? gradient;
  final bool clipOval;

  @override
  Widget build(BuildContext context) {
    final clipper = clipOval
        ? ClipOval(child: _buildFiltered(context))
        : ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: _buildFiltered(context),
          );
    return clipper;
  }

  Widget _buildFiltered(BuildContext context) {
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;
    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        gradient: gradient,
        shape: clipOval ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: clipOval ? null : BorderRadius.circular(borderRadius),
        border: borderColor != null ? Border.all(color: borderColor!) : null,
      ),
      child: child,
    );

    if (isAndroid) {
      return content;
    }

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
      child: content,
    );
  }
}

/// Frosted or liquid-glass track background for pill bars and panels.
class DuckLiquidGlassTrack extends StatelessWidget {
  const DuckLiquidGlassTrack({
    super.key,
    required this.borderRadius,
    required this.isLight,
    required this.child,
    this.isDragging = false,
    this.fallbackColor,
    this.fallbackBorderColor,
    this.blurSigma = 16,
  });

  final double borderRadius;
  final bool isLight;
  final Widget child;
  final bool isDragging;
  final Color? fallbackColor;
  final Color? fallbackBorderColor;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    if (!DuckLiquidGlass.shouldUseLiquidGlass(context)) {
      return DuckFrostedSurface(
        borderRadius: borderRadius,
        blurSigma: blurSigma,
        color: fallbackColor,
        borderColor: fallbackBorderColor,
        child: child,
      );
    }

    return LiquidGlassLayer(
      settings: DuckLiquidGlass.track(
        isLight: isLight,
        isDragging: isDragging,
      ),
      child: LiquidGlass(
        shape: LiquidRoundedSuperellipse(borderRadius: borderRadius),
        child: child,
      ),
    );
  }
}

/// Draggable active pill with gold-tinted liquid glass.
class DuckLiquidGlassPill extends StatelessWidget {
  const DuckLiquidGlassPill({
    super.key,
    required this.width,
    required this.height,
    required this.borderRadius,
    required this.goldColor,
    this.isDragging = false,
    this.enableStretch = true,
    this.enableGlow = true,
    this.child,
  });

  final double width;
  final double height;
  final double borderRadius;
  final Color goldColor;
  final bool isDragging;
  final bool enableStretch;
  final bool enableGlow;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (!DuckLiquidGlass.shouldUseLiquidGlass(context)) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          color: goldColor,
          boxShadow: [
            BoxShadow(
              color: goldColor.withValues(alpha: isDragging ? 0.5 : 0.3),
              blurRadius: isDragging ? 14 : 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: child,
      );
    }

    Widget glassChild = LiquidGlass.withOwnLayer(
      settings: DuckLiquidGlass.pill(
        goldColor: goldColor,
        isDragging: isDragging,
      ),
      shape: LiquidRoundedSuperellipse(borderRadius: borderRadius),
      child: enableGlow
          ? GlassGlow(
              glowColor: Colors.white.withValues(alpha: 0.35),
              glowRadius: 0.8,
              child: SizedBox(width: width, height: height, child: child),
            )
          : SizedBox(width: width, height: height, child: child),
    );

    if (enableStretch) {
      glassChild = LiquidStretch(
        stretch: isDragging ? 0.45 : 0.35,
        interactionScale: isDragging ? 1.06 : 1.04,
        child: glassChild,
      );
    }

    return SizedBox(width: width, height: height, child: glassChild);
  }
}

/// Wrapper for LiquidGlassLayer that respects device platform and accessibility settings.
class DuckLiquidGlassLayer extends StatelessWidget {
  const DuckLiquidGlassLayer({
    super.key,
    required this.settings,
    required this.child,
  });

  final LiquidGlassSettings settings;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!DuckLiquidGlass.shouldUseLiquidGlass(context)) {
      return child;
    }
    return LiquidGlassLayer(
      settings: settings,
      child: child,
    );
  }
}

/// Generic liquid-glass surface (panel, capsule, etc.).
class DuckLiquidGlassSurface extends StatelessWidget {
  const DuckLiquidGlassSurface({
    super.key,
    required this.borderRadius,
    required this.child,
    this.isLight = false,
    this.isDragging = false,
    this.variant = DuckLiquidGlassVariant.panel,
    this.goldColor,
    this.fallbackColor,
    this.fallbackBorderColor,
    this.fallbackGradient,
    this.blurSigma = 18,
    this.clipOval = false,
    this.boxShadow,
    this.useOwnLayer = true,
  });

  final double borderRadius;
  final Widget child;
  final bool isLight;
  final bool isDragging;
  final DuckLiquidGlassVariant variant;
  final Color? goldColor;
  final Color? fallbackColor;
  final Color? fallbackBorderColor;
  final Gradient? fallbackGradient;
  final double blurSigma;
  final bool clipOval;
  final List<BoxShadow>? boxShadow;
  final bool useOwnLayer;

  LiquidGlassSettings _settings() {
    return switch (variant) {
      DuckLiquidGlassVariant.panel =>
        DuckLiquidGlass.panel(isLight: isLight),
      DuckLiquidGlassVariant.button =>
        DuckLiquidGlass.button(isDragging: isDragging),
      DuckLiquidGlassVariant.capsule =>
        DuckLiquidGlass.capsule(isDragging: isDragging),
      DuckLiquidGlassVariant.pill when goldColor != null =>
        DuckLiquidGlass.pill(goldColor: goldColor!, isDragging: isDragging),
      DuckLiquidGlassVariant.pill =>
        DuckLiquidGlass.button(isDragging: isDragging),
      DuckLiquidGlassVariant.track =>
        DuckLiquidGlass.track(isLight: isLight, isDragging: isDragging),
    };
  }

  LiquidShape _shape() {
    if (clipOval) return const LiquidOval();
    return LiquidRoundedSuperellipse(borderRadius: borderRadius);
  }

  @override
  Widget build(BuildContext context) {
    final wrapped = boxShadow != null
        ? Container(
            decoration: BoxDecoration(boxShadow: boxShadow),
            child: child,
          )
        : child;

    if (!DuckLiquidGlass.shouldUseLiquidGlass(context)) {
      return DuckFrostedSurface(
        borderRadius: borderRadius,
        blurSigma: blurSigma,
        color: fallbackColor,
        borderColor: fallbackBorderColor,
        gradient: fallbackGradient,
        clipOval: clipOval,
        child: wrapped,
      );
    }

    final glassGlow = GlassGlow(
      glowColor: Colors.white.withValues(alpha: 0.28),
      glowRadius: 0.75,
      child: wrapped,
    );

    return Container(
      decoration: boxShadow != null ? BoxDecoration(boxShadow: boxShadow) : null,
      child: useOwnLayer
          ? LiquidGlass.withOwnLayer(
              settings: _settings(),
              shape: _shape(),
              child: glassGlow,
            )
          : LiquidGlass(
              shape: _shape(),
              child: glassGlow,
            ),
    );
  }
}

enum DuckLiquidGlassVariant { track, pill, button, capsule, panel }
