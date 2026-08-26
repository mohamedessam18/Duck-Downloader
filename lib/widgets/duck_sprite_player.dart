import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../constants/asset_paths.dart';

class DuckSpritePlayer extends StatefulWidget {
  const DuckSpritePlayer({
    super.key,
    required this.sprite,
    required this.size,
    this.reduceMotion = false,
  });

  final DuckSpriteState sprite;
  final double size;
  final bool reduceMotion;

  @override
  State<DuckSpritePlayer> createState() => _DuckSpritePlayerState();
}

class _DuckSpritePlayerState extends State<DuckSpritePlayer>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  int _index = 0;
  bool _precached = false;

  @override
  void initState() {
    super.initState();
    _setupController();
  }

  @override
  void didUpdateWidget(DuckSpritePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final spriteChanged = oldWidget.sprite != widget.sprite ||
        !listEquals(oldWidget.sprite.frames, widget.sprite.frames) ||
        oldWidget.sprite.fps != widget.sprite.fps ||
        oldWidget.sprite.loop != widget.sprite.loop ||
        oldWidget.reduceMotion != widget.reduceMotion;

    if (spriteChanged) {
      _controller?.dispose();
      _controller = null;
      _index = 0;
      _precached = false;
      _setupController();
    }
  }

  void _setupController() {
    final frames = widget.sprite.frames;
    if (widget.reduceMotion || frames.length <= 1) {
      return;
    }

    final duration = Duration(
      milliseconds: (1000 * frames.length / widget.sprite.fps).round(),
    );
    _controller = AnimationController(vsync: this, duration: duration);

    void tick() {
      if (!mounted || _controller == null || frames.isEmpty) return;
      final progress = _controller!.value.clamp(0.0, 0.999999);
      final next =
          (progress * frames.length).floor().clamp(0, frames.length - 1);
      if (next != _index) {
        setState(() => _index = next);
      }
    }

    _controller!.addListener(tick);

    if (widget.sprite.loop) {
      _controller!.repeat();
    } else {
      _controller!.addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _index = frames.length - 1);
        }
      });
      _controller!.forward();
    }

    tick();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frames = widget.sprite.frames;
    if (frames.isEmpty) {
      return SizedBox(width: widget.size, height: widget.size);
    }

    if (!_precached && !widget.reduceMotion) {
      _precached = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final target = (widget.size * dpr).round();
        for (final frame in frames) {
          precacheImage(
            ResizeImage(AssetImage(frame), width: target, allowUpscaling: false),
            context,
          );
        }
      });
    }

    final frameIndex =
        widget.reduceMotion ? 0 : _index.clamp(0, frames.length - 1);
    final asset = frames[frameIndex];

    // cacheWidth decodes to the size actually drawn instead of the source's
    // full 512px. Twelve frames held at native size cost several megabytes of
    // decoded bitmap per state for no visible gain.
    final cacheWidth =
        (widget.size * MediaQuery.devicePixelRatioOf(context)).round();

    return Image.asset(
      asset,
      key: ValueKey(asset),
      width: widget.size,
      height: widget.size,
      cacheWidth: cacheWidth,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
    );
  }
}
