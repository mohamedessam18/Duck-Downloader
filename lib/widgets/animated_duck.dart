import 'package:flutter/material.dart';

import '../constants/asset_paths.dart';
import '../models/download_models.dart';
import '../theme/duck_theme.dart';
import 'duck_sprite_player.dart';

class AnimatedDuck extends StatefulWidget {
  const AnimatedDuck({
    super.key,
    required this.flow,
    required this.compact,
    required this.scale,
    required this.onTap,
  });

  final DuckFlow flow;
  final bool compact;
  final double scale;
  final VoidCallback onTap;

  @override
  State<AnimatedDuck> createState() => _AnimatedDuckState();
}

class _AnimatedDuckState extends State<AnimatedDuck>
    with TickerProviderStateMixin {
  late final AnimationController _glowController;
  late final AnimationController _pressController;
  late final Animation<double> _glow;
  late final Animation<double> _pressScale;
  late DuckSpriteState _sprite;

  @override
  void initState() {
    super.initState();
    _sprite = DuckAssets.spriteFor(widget.flow);
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat(reverse: true);
    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      value: 1,
    );

    _glow = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );
    _pressScale = Tween<double>(begin: 0.96, end: 1.0).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeOut),
    );
  }

  @override
  void didUpdateWidget(AnimatedDuck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flow != widget.flow) {
      _sprite = DuckAssets.spriteFor(widget.flow);
    }
  }

  @override
  void dispose() {
    _glowController.dispose();
    _pressController.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) => _pressController.reverse();
  void _onTapUp(TapUpDetails _) => _pressController.forward();
  void _onTapCancel() => _pressController.forward();

  @override
  Widget build(BuildContext context) {
    final colors = DuckColors.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duckSize = (widget.compact ? 160.0 : 240.0) * widget.scale;
    final ringWidth = (widget.compact ? 230.0 : 300.0) * widget.scale;
    final ringHeight = (widget.compact ? 72.0 : 92.0) * widget.scale;
    final ringBottom = (widget.compact ? 20.0 : 30.0) * widget.scale;

    final duckSprite = AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: DuckSpritePlayer(
        key: ValueKey(widget.flow),
        sprite: _sprite,
        size: duckSize,
        reduceMotion: reduceMotion,
      ),
    );

    return Semantics(
      button: true,
      label: 'Tap duck',
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: _onTapDown,
        onTapUp: _onTapUp,
        onTapCancel: _onTapCancel,
        child: AnimatedBuilder(
          animation: Listenable.merge([_glowController, _pressController]),
          builder: (context, child) {
            final glowAlpha =
                reduceMotion ? 0.14 : 0.08 + _glow.value * 0.14;
            final shadowAlpha =
                reduceMotion ? 0.15 : 0.12 + _glow.value * 0.1;

            return Transform.scale(
              scale: _pressScale.value,
              child: SizedBox(
                width: 360 * widget.scale,
                height: (widget.compact ? 178 : 250) * widget.scale,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      bottom: ringBottom,
                      child: Container(
                        width: ringWidth,
                        height: ringHeight,
                        decoration: BoxDecoration(
                          borderRadius:
                              BorderRadius.circular(DuckColors.radiusPill),
                          border: Border.all(
                            color: colors.gold.withValues(alpha: glowAlpha),
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  colors.gold.withValues(alpha: shadowAlpha),
                              blurRadius: 40,
                              spreadRadius: -12,
                            ),
                          ],
                        ),
                      ),
                    ),
                    child!,
                  ],
                ),
              ),
            );
          },
          child: duckSprite,
        ),
      ),
    );
  }
}
