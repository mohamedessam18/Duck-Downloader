import 'dart:async';

import 'package:flutter/material.dart';

import '../core/haptics.dart';

/// Shared motion vocabulary. Keeping the curves and durations in one place is
/// what stops a UI from feeling like several apps stitched together.
class DuckMotion {
  DuckMotion._();

  /// Press / release of a tappable surface.
  static const pressDuration = Duration(milliseconds: 110);
  static const pressCurve = Curves.easeOut;

  /// Content arriving on screen.
  static const entryDuration = Duration(milliseconds: 380);
  static const entryCurve = Curves.easeOutCubic;

  /// Screen- and tab-level changes.
  /// Long enough to read as movement.
  ///
  /// This started at 260ms as a cross-fade, went to 220 when it became a
  /// slide, and both were fast enough that the screen simply appeared to be
  /// replaced. A transition the user cannot perceive is doing none of the work
  /// a transition exists to do: showing where the new screen came from, and so
  /// where the old one went. Cupertino's own 500ms is the other extreme for an
  /// app you navigate this often.
  static const transitionDuration = Duration(milliseconds: 400);
  static const transitionCurve = Curves.easeOutCubic;

  /// Delay between successive list items in a staggered entry, capped so a long
  /// list never makes the user wait for the bottom of the screen to fill in.
  static Duration staggerFor(int index) {
    return Duration(milliseconds: 40 * (index.clamp(0, 8)));
  }
}

/// Wraps a tappable surface so it dips slightly and ticks under the finger.
///
/// This is the difference between a card that feels like a physical object and
/// one that feels like a picture of a card.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.97,
    this.haptics = true,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final bool haptics;
  final BorderRadius? borderRadius;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _setPressed(true) : null,
      onTapUp: enabled ? (_) => _setPressed(false) : null,
      onTapCancel: enabled ? () => _setPressed(false) : null,
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptics) DuckHaptics.tap();
              widget.onTap!.call();
            },
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              if (widget.haptics) DuckHaptics.longPress();
              widget.onLongPress!.call();
            },
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: DuckMotion.pressDuration,
        curve: DuckMotion.pressCurve,
        child: AnimatedOpacity(
          opacity: _pressed ? 0.86 : 1.0,
          duration: DuckMotion.pressDuration,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Fades and lifts a widget into place once, offset by its position in a list.
///
/// Used for list and grid items so a library doesn't snap into existence all at
/// once. The animation runs on first build only — scrolling never replays it.
class EntranceFade extends StatefulWidget {
  const EntranceFade({
    super.key,
    required this.child,
    this.index = 0,
    this.offset = const Offset(0, 0.06),
  });

  final Widget child;
  final int index;

  /// Starting displacement as a fraction of the child's own size.
  final Offset offset;

  @override
  State<EntranceFade> createState() => _EntranceFadeState();
}

class _EntranceFadeState extends State<EntranceFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: DuckMotion.entryDuration,
  );

  /// Held so dispose can cancel it.
  ///
  /// This used to be `Future.delayed`, which cannot be cancelled: navigating
  /// away before the stagger elapsed left a live timer holding this State
  /// until it fired. The `mounted` check kept that harmless at runtime, but a
  /// pending timer outliving its widget also trips the test framework, so any
  /// screen built from these could not be widget-tested at all.
  Timer? _startTimer;

  @override
  void initState() {
    super.initState();
    final delay = DuckMotion.staggerFor(widget.index);
    if (delay == Duration.zero) {
      _controller.forward();
    } else {
      _startTimer = Timer(delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect the OS "reduce motion" setting: show the content immediately.
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;

    final curved = CurvedAnimation(
      parent: _controller,
      curve: DuckMotion.entryCurve,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(begin: widget.offset, end: Offset.zero)
            .animate(curved),
        child: widget.child,
      ),
    );
  }
}
