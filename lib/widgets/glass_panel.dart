import 'package:flutter/material.dart';

import '../theme/duck_theme.dart';
import 'duck_liquid_glass.dart';

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin,
    this.maxWidth = 540,
    this.borderRadius = DuckColors.radiusLg,
    this.blurSigma = 16,
    this.tint,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double maxWidth;
  final double borderRadius;
  final double blurSigma;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final colors = DuckColors.of(context);
    final isLight = Theme.of(context).brightness == Brightness.light;
    final fill = tint ?? colors.glassFill;

    return Center(
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(maxWidth: maxWidth),
        margin: margin ?? const EdgeInsets.only(top: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: isLight ? colors.lightCardShadow : colors.cardShadow,
        ),
        child: DuckLiquidGlassSurface(
          borderRadius: borderRadius,
          isLight: isLight,
          variant: DuckLiquidGlassVariant.panel,
          blurSigma: blurSigma,
          fallbackColor: fill,
          fallbackBorderColor:
              colors.glassBorder.withValues(alpha: isLight ? 0.12 : 0.28),
          fallbackGradient: tint == null
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: isLight ? 0.45 : 0.18),
                    Colors.white.withValues(alpha: isLight ? 0.15 : 0.04),
                  ],
                )
              : null,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
