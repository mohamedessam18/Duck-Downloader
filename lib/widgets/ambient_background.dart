import 'package:flutter/material.dart';

import '../theme/duck_theme.dart';

class AmbientBackground extends StatefulWidget {
  const AmbientBackground({
    super.key,
    required this.child,
    this.padding,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground>
    with TickerProviderStateMixin {
  late final AnimationController _goldController;
  late final AnimationController _amberController;
  late final Animation<Alignment> _goldAlignment;
  late final Animation<Alignment> _amberAlignment;

  @override
  void initState() {
    super.initState();
    _goldController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    _amberController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    );

    _goldAlignment = TweenSequence<Alignment>([
      TweenSequenceItem(
        tween: AlignmentTween(
          begin: const Alignment(0, -0.22),
          end: const Alignment(0.08, -0.12),
        ),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: AlignmentTween(
          begin: const Alignment(0.08, -0.12),
          end: const Alignment(-0.06, -0.2),
        ),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: AlignmentTween(
          begin: const Alignment(-0.06, -0.2),
          end: const Alignment(0, -0.22),
        ),
        weight: 1,
      ),
    ]).animate(CurvedAnimation(parent: _goldController, curve: Curves.easeInOut));

    _amberAlignment = TweenSequence<Alignment>([
      TweenSequenceItem(
        tween: AlignmentTween(
          begin: const Alignment(-0.1, 0.05),
          end: const Alignment(0.12, 0.1),
        ),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: AlignmentTween(
          begin: const Alignment(0.12, 0.1),
          end: const Alignment(-0.08, -0.02),
        ),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: AlignmentTween(
          begin: const Alignment(-0.08, -0.02),
          end: const Alignment(-0.1, 0.05),
        ),
        weight: 1,
      ),
    ]).animate(
      CurvedAnimation(parent: _amberController, curve: Curves.easeInOut),
    );

    _goldController.repeat();
    _amberController.repeat();
  }

  @override
  void dispose() {
    _goldController.dispose();
    _amberController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DuckColors.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    if (reduceMotion) {
      return ColoredBox(
        color: colors.background,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.18),
              radius: 0.78,
              colors: [colors.ambientGold, colors.background],
            ),
          ),
          child: widget.padding != null
              ? Padding(padding: widget.padding!, child: widget.child)
              : widget.child,
        ),
      );
    }

    return ColoredBox(
      color: colors.background,
      child: AnimatedBuilder(
        animation: Listenable.merge([_goldController, _amberController]),
        builder: (context, child) {
          return Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: _goldAlignment.value,
                    radius: 0.72,
                    colors: [colors.ambientGold, Colors.transparent],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: _amberAlignment.value,
                    radius: 0.55,
                    colors: [colors.ambientAmber, Colors.transparent],
                  ),
                ),
              ),
              if (widget.padding != null)
                Padding(padding: widget.padding!, child: child!)
              else
                child!,
            ],
          );
        },
        child: widget.child,
      ),
    );
  }
}
