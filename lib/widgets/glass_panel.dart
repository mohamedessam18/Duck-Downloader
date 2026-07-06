import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/duck_theme.dart';

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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(borderRadius),
                border: Border.all(color: colors.glassBorder, width: 1),
                boxShadow: isLight ? colors.lightCardShadow : colors.cardShadow,
              ),
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}
