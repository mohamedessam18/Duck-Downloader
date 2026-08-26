import 'dart:async';

import 'package:flutter/material.dart';

import '../constants/asset_paths.dart';
import '../models/download_models.dart';
import '../theme/duck_theme.dart';
import 'duck_rive_player.dart';
import 'duck_sprite_player.dart';

class AnimatedDuck extends StatefulWidget {
  const AnimatedDuck({
    super.key,
    required this.flow,
    required this.compact,
    required this.scale,
    required this.onTap,
    this.progress = 0,
  });

  final DuckFlow flow;
  final bool compact;
  final double scale;
  final VoidCallback onTap;

  /// Live download completion, 0-100. Only the Rive artwork uses it — the
  /// sprite flipbook has no way to represent a partial state.
  final int progress;

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

  /// The flow used as key for AnimatedSwitcher (may differ from widget.flow
  /// while the return-to-idle delay is counting down).
  late DuckFlow _displayFlow;

  /// Timer that fires after a transient flow (success / error) to switch
  /// the duck back to idle.
  Timer? _idleReturnTimer;

  /// Set once the Rive artwork reports it cannot load, after which the sprite
  /// flipbook takes over for the rest of the session.
  bool _riveUnavailable = false;

  /// Bumped on every tap so [DuckRivePlayer] can fire its tap trigger without
  /// this widget holding a reference to the Rive controller.
  int _tapSignal = 0;

  /// How long to show the success / error animation before returning to idle.
  static const _idleReturnDelay = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _displayFlow = widget.flow;
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
    _scheduleIdleReturnIfNeeded(widget.flow);
  }

  @override
  void didUpdateWidget(AnimatedDuck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flow != widget.flow) {
      _idleReturnTimer?.cancel();
      _idleReturnTimer = null;
      _displayFlow = widget.flow;
      _sprite = DuckAssets.spriteFor(widget.flow);
      _scheduleIdleReturnIfNeeded(widget.flow);
    }
  }

  /// Schedules a return to idle after [_idleReturnDelay] for transient flows.
  void _scheduleIdleReturnIfNeeded(DuckFlow flow) {
    if (flow == DuckFlow.success || flow == DuckFlow.error) {
      _idleReturnTimer = Timer(_idleReturnDelay, () {
        if (!mounted) return;
        setState(() {
          _displayFlow = DuckFlow.idle;
          _sprite = DuckAssets.duckIdleSprite();
        });
      });
    }
  }

  @override
  void dispose() {
    _idleReturnTimer?.cancel();
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

    // Prefer the Rive artboard when the artwork is bundled: it interpolates at
    // the display's refresh rate and can react to live progress, neither of
    // which a 5fps flipbook can do. _riveUnavailable flips permanently the
    // first time the file is missing or unreadable, which is the normal state
    // until a .riv is dropped into assets/rive/.
    final Widget duckSprite = _riveUnavailable
        ? AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) {
              return FadeTransition(opacity: animation, child: child);
            },
            child: DuckSpritePlayer(
              key: ValueKey(_displayFlow),
              sprite: _sprite,
              size: duckSize,
              reduceMotion: reduceMotion,
            ),
          )
        : DuckRivePlayer(
            flow: _displayFlow,
            size: duckSize,
            progress: widget.progress,
            tapSignal: _tapSignal,
            onUnavailable: () {
              if (mounted) setState(() => _riveUnavailable = true);
            },
          );

    return Semantics(
      button: true,
      label: 'Tap duck',
      child: GestureDetector(
        onTap: () {
          if (mounted) setState(() => _tapSignal++);
          widget.onTap();
        },
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
