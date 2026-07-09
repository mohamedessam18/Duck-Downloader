import 'dart:ui';
import 'package:flutter/material.dart';

class LiquidGlassInteractiveButton extends StatefulWidget {
  const LiquidGlassInteractiveButton({
    super.key,
    required this.child,
    required this.onTap,
    this.size,
  });

  final Widget child;
  final VoidCallback onTap;
  final double? size;

  @override
  State<LiquidGlassInteractiveButton> createState() => _LiquidGlassInteractiveButtonState();
}

class _LiquidGlassInteractiveButtonState extends State<LiquidGlassInteractiveButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<Offset> _snapAnimation;
  
  Offset _dragOffset = Offset.zero;
  bool _isDragging = false;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _snapAnimation = _animationController.drive(
      Tween<Offset>(begin: Offset.zero, end: Offset.zero),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _onPanStart(DragStartDetails details) {
    _animationController.stop();
    setState(() {
      _isPressed = true;
      _isDragging = false;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      _dragOffset += details.delta;
      
      // Rubber-band damping formula (max 10px shift)
      final distance = _dragOffset.distance;
      if (distance > 4.0) {
        final dampedDistance = 4.0 + (distance - 4.0).clamp(0.0, 40.0) * 0.15;
        _dragOffset = Offset.fromDirection(_dragOffset.direction, dampedDistance.clamp(0.0, 10.0));
      }
      
      if (distance > 5.0) {
        _isDragging = true;
      }
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (!_isDragging) {
      widget.onTap();
    }
    
    setState(() {
      _isPressed = false;
      _isDragging = false;
    });

    _snapAnimation = _animationController.drive(
      Tween<Offset>(begin: _dragOffset, end: Offset.zero).chain(
        CurveTween(curve: Curves.easeOutBack),
      ),
    );
    
    _animationController.forward(from: 0.0).then((_) {
      if (mounted) {
        setState(() {
          _dragOffset = Offset.zero;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;
    
    if (isAndroid) {
      // Android: Standard touch feedback, no drag displacement
      return InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(99),
        child: widget.child,
      );
    }

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final useLiquidEffects = !reduceMotion;

    final scale = _isPressed ? (_isDragging ? 1.08 : 0.94) : 1.0;
    final size = widget.size ?? 48.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      onPanCancel: () {
        if (mounted) {
          setState(() {
            _isPressed = false;
            _isDragging = false;
            _dragOffset = Offset.zero;
          });
        }
      },
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // 1. Ghost anchor left behind when dragged (Static background outline)
            if (_isDragging && useLiquidEffects)
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withOpacity(0.08),
                    width: 1,
                  ),
                ),
              ),
            // 2. Sliding/Stretching Glass Backing (Moves with drag!)
            AnimatedBuilder(
              animation: _animationController,
              builder: (context, _) {
                final animatedOffset = _animationController.isAnimating ? _snapAnimation.value : _dragOffset;
                return Transform.translate(
                  offset: animatedOffset,
                  child: Transform.scale(
                    scale: scale,
                    child: Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: useLiquidEffects ? [
                          BoxShadow(
                            color: Colors.black.withOpacity(_isDragging ? 0.35 : 0.2),
                            blurRadius: _isDragging ? 14 : 8,
                            offset: _isDragging 
                                ? Offset(-animatedOffset.dx * 0.15, -animatedOffset.dy * 0.15 + 4)
                                : const Offset(0, 4),
                          ),
                        ] : null,
                      ),
                      child: ClipOval(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Colors.white.withOpacity(0.18),
                                  Colors.white.withOpacity(0.04),
                                ],
                              ),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.24),
                                width: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            // 3. Icon child stays centered (doesn't translate, or moves tiny bit like 4% for parallax!)
            AnimatedBuilder(
              animation: _animationController,
              builder: (context, _) {
                final animatedOffset = _animationController.isAnimating ? _snapAnimation.value : _dragOffset;
                // Minor parallax shift (4%) to give depth
                final iconOffset = _isDragging ? animatedOffset * 0.04 : Offset.zero;
                return Transform.translate(
                  offset: iconOffset,
                  child: Transform.scale(
                    scale: _isPressed ? 0.92 : 1.0,
                    child: widget.child,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
