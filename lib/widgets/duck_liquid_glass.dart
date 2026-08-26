import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:liquid_glass_plus/liquid_glass_plus.dart';

/// Duck-themed liquid glass primitives for iOS (Impeller shaders).
class DuckLiquidGlass {
  DuckLiquidGlass._();

  /// The Impeller shader-based liquid glass is iOS-only.
  static bool shouldUseLiquidGlass(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.iOS) return false;
    return !MediaQuery.disableAnimationsOf(context);
  }

  /// Whether to render real backdrop blur at all.
  ///
  /// Android used to be excluded entirely, which left every "glass" surface in
  /// the app as a flat coloured box there. Android renders `BackdropFilter`
  /// perfectly well; only the accessibility "reduce motion / animations"
  /// setting should fall back to an opaque surface.
  static bool blurEnabled(BuildContext context) {
    return !MediaQuery.disableAnimationsOf(context);
  }

  /// Backdrop blur is the most expensive thing on screen, so Android — which
  /// covers a much wider hardware range — gets a slightly cheaper radius.
  static double blurSigmaFor(BuildContext context, double sigma) {
    return Theme.of(context).platform == TargetPlatform.android
        ? sigma * 0.75
        : sigma;
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
    this.rimLight = true,
  });

  final double borderRadius;
  final Widget child;
  final double blurSigma;
  final Color? color;
  final Color? borderColor;
  final Gradient? gradient;
  final bool clipOval;

  /// Draws a soft highlight along the top edge and a shadow along the bottom,
  /// the way light catches a real pane of glass. This is what reads as "depth"
  /// rather than a flat translucent rectangle.
  final bool rimLight;

  @override
  Widget build(BuildContext context) {
    final filtered = _buildFiltered(context);
    return clipOval
        ? ClipOval(child: filtered)
        : ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: filtered,
          );
  }

  Widget _buildFiltered(BuildContext context) {
    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        gradient: gradient,
        shape: clipOval ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: clipOval ? null : BorderRadius.circular(borderRadius),
        border: borderColor != null ? Border.all(color: borderColor!) : null,
      ),
      child: child,
    );

    if (rimLight) {
      content = Stack(
        fit: StackFit.passthrough,
        children: [
          content,
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: clipOval ? BoxShape.circle : BoxShape.rectangle,
                  borderRadius:
                      clipOval ? null : BorderRadius.circular(borderRadius),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.16),
                      Colors.white.withValues(alpha: 0.02),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.06),
                    ],
                    stops: const [0.0, 0.12, 0.6, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (!DuckLiquidGlass.blurEnabled(context)) return content;

    return BackdropFilter(
      filter: ImageFilter.blur(
        sigmaX: DuckLiquidGlass.blurSigmaFor(context, blurSigma),
        sigmaY: DuckLiquidGlass.blurSigmaFor(context, blurSigma),
      ),
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
      // Non-iOS fallback. A flat gold rectangle read as unfinished next to the
      // frosted track behind it, so this builds the same sense of a lit,
      // rounded object out of plain decoration: a vertical sheen, a bright top
      // rim, and a coloured glow that swells while dragging.
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(goldColor, Colors.white, 0.28)!,
              goldColor,
              Color.lerp(goldColor, Colors.black, 0.12)!,
            ],
            stops: const [0.0, 0.55, 1.0],
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: isDragging ? 0.55 : 0.35),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: goldColor.withValues(alpha: isDragging ? 0.55 : 0.34),
              blurRadius: isDragging ? 22 : 14,
              spreadRadius: isDragging ? 1 : 0,
              offset: const Offset(0, 3),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 8,
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
