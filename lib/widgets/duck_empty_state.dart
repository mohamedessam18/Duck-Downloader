import 'package:flutter/material.dart';

import '../theme/duck_theme.dart';
import 'duck_liquid_glass.dart';
import 'duck_motion.dart';

/// The empty view for a library tab.
///
/// This is the first screen a new user meets in three of the four tabs, so it
/// carries the duck, says what belongs here, and offers the one action that
/// fills it — rather than a line of grey text.
class DuckEmptyState extends StatelessWidget {
  const DuckEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.imageAsset,
    this.actionLabel,
    this.onAction,
  });

  /// Shown inside the glass medallion when [imageAsset] is null.
  final IconData icon;
  final String title;
  final String message;
  final String? imageAsset;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = DuckColors.of(context);
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: EntranceFade(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Medallion(
                icon: icon,
                imageAsset: imageAsset,
                colors: colors,
                isLight: isLight,
              ),
              const SizedBox(height: 26),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 26),
                Pressable(
                  onTap: onAction,
                  pressedScale: 0.95,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 26,
                      vertical: 13,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(DuckColors.radiusPill),
                      gradient: LinearGradient(
                        colors: [colors.gold, colors.warmGold],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: colors.gold.withValues(alpha: 0.32),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.content_paste_rounded,
                          size: 17,
                          color: Color(0xFF101112),
                        ),
                        const SizedBox(width: 9),
                        Text(
                          actionLabel!,
                          style: const TextStyle(
                            color: Color(0xFF101112),
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Glass disc holding the duck (or a fallback icon), ringed with a gold glow so
/// it reads as a lit object floating over the ambient background.
class _Medallion extends StatelessWidget {
  const _Medallion({
    required this.icon,
    required this.imageAsset,
    required this.colors,
    required this.isLight,
  });

  final IconData icon;
  final String? imageAsset;
  final DuckColors colors;
  final bool isLight;

  @override
  Widget build(BuildContext context) {
    const size = 132.0;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: colors.gold.withValues(alpha: isLight ? 0.16 : 0.22),
            blurRadius: 40,
            spreadRadius: 2,
          ),
        ],
      ),
      child: DuckFrostedSurface(
        borderRadius: size / 2,
        clipOval: true,
        blurSigma: 20,
        color: colors.glassFill,
        borderColor: colors.glassBorder,
        child: Center(
          child: imageAsset != null
              ? Padding(
                  padding: const EdgeInsets.all(22),
                  child: Image.asset(
                    imageAsset!,
                    fit: BoxFit.contain,
                    // The duck art is optional at runtime; never let a missing
                    // asset turn an empty list into a broken-image box.
                    errorBuilder: (_, _, _) =>
                        Icon(icon, size: 46, color: colors.gold),
                  ),
                )
              : Icon(icon, size: 46, color: colors.gold),
        ),
      ),
    );
  }
}
