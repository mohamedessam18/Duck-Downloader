import 'dart:ui';
import 'package:flutter/material.dart';
import 'media_colors.dart';
import 'media_utils.dart';

class MediaSlider extends StatefulWidget {
  const MediaSlider({
    super.key,
    required this.position,
    required this.duration,
    required this.onChanged,
    this.activeColor,
    this.inactiveColor,
    this.thumbColor,
    this.showTimeLabels = true,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onChanged;
  final Color? activeColor;
  final Color? inactiveColor;
  final Color? thumbColor;
  final bool showTimeLabels;

  @override
  State<MediaSlider> createState() => _MediaSliderState();
}

class _MediaSliderState extends State<MediaSlider> {
  double? _dragPositionX;
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;
    final total = widget.duration.inMilliseconds;
    final current = total <= 0
        ? 0.0
        : widget.position.inMilliseconds.clamp(0, total).toDouble();
    final timeStyle = TextStyle(
      color: mediaMuted,
      fontSize: 12,
      fontWeight: FontWeight.w700,
    );

    final resolvedActiveColor = widget.activeColor ?? mediaGold;
    final resolvedInactiveColor = widget.inactiveColor ?? Colors.white24;
    final resolvedThumbColor = widget.thumbColor ?? mediaGold;

    if (isAndroid) {
      // Android layout: standard material slider
      final sliderWidget = SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3.0,
          activeTrackColor: resolvedActiveColor,
          inactiveTrackColor: resolvedInactiveColor,
          thumbColor: resolvedThumbColor,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
          overlayColor: resolvedActiveColor.withOpacity(0.12),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 18.0),
        ),
        child: Slider(
          value: current,
          min: 0,
          max: total <= 0 ? 1 : total.toDouble(),
          onChanged: total <= 0
              ? null
              : (value) => widget.onChanged(Duration(milliseconds: value.round())),
        ),
      );

      if (!widget.showTimeLabels) {
        return sliderWidget;
      }

      return Column(
        children: [
          sliderWidget,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(formatMediaDuration(widget.position), style: timeStyle),
                Text(formatMediaDuration(widget.duration), style: timeStyle),
              ],
            ),
          ),
        ],
      );
    }

    // iOS premium liquid glass seek bar with rubber-banding
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final useLiquidEffects = !reduceMotion;

    final sliderWidget = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;

          // Guard against zero or near-zero width during first layout frame (iOS)
          if (totalWidth < 24) return const SizedBox.shrink();

          final thumbSize = _isDragging ? 18.0 : 14.0;
          final trackHeight = _isDragging ? 6.0 : 4.0;
          
          final trackLeft = 10.0;
          final trackRight = totalWidth - 10.0;
          final usableWidth = (trackRight - trackLeft).clamp(1.0, double.infinity);

          final currentFraction = total <= 0 ? 0.0 : current / total;
          final defaultThumbLeft = trackLeft + (currentFraction * usableWidth) - (thumbSize / 2.0);

          final duration = _isDragging ? Duration.zero : const Duration(milliseconds: 250);
          final curve = _isDragging 
              ? Curves.linear 
              : (useLiquidEffects ? Curves.easeOutBack : Curves.easeInOut);
          final fillCurve = _isDragging 
              ? Curves.linear 
              : (useLiquidEffects ? Curves.easeOutCubic : Curves.easeInOut);


          double thumbLeft = _isDragging ? _dragPositionX! - (thumbSize / 2.0) : defaultThumbLeft;
          
          final minLeft = trackLeft - (thumbSize / 2.0);
          final maxLeft = trackRight - (thumbSize / 2.0);
          
          if (thumbLeft < minLeft) {
            final diff = minLeft - thumbLeft;
            thumbLeft = minLeft - diff.clamp(0.0, 45.0) * 0.35;
          } else if (thumbLeft > maxLeft) {
            final diff = thumbLeft - maxLeft;
            thumbLeft = maxLeft + diff.clamp(0.0, 45.0) * 0.35;
          }

          final fillCenter = thumbLeft + (thumbSize / 2.0);
          final fillWidth = (fillCenter - trackLeft).clamp(0.0, usableWidth + 16.0);


          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (details) {
              if (total <= 0) return;
              setState(() {
                _isDragging = true;
                _dragPositionX = details.localPosition.dx.clamp(trackLeft, trackRight);
              });
            },
            onHorizontalDragUpdate: (details) {
              if (total <= 0) return;
              final touchX = details.localPosition.dx;
              setState(() {
                _dragPositionX = touchX;
              });
              final seekFraction = ((touchX - trackLeft) / usableWidth).clamp(0.0, 1.0);
              widget.onChanged(Duration(milliseconds: (seekFraction * total).round()));
            },
            onHorizontalDragEnd: (details) {
              setState(() {
                _isDragging = false;
              });
            },
            child: SizedBox(
              height: 32,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  // 1. Inactive Track
                  Container(
                    height: trackHeight,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: resolvedInactiveColor,
                      borderRadius: BorderRadius.circular(trackHeight / 2.0),
                    ),
                  ),
                  // 2. Active Progress Fill
                  Positioned(
                    left: trackLeft,
                    child: AnimatedContainer(
                      duration: duration,
                      curve: fillCurve,
                      height: trackHeight,
                      width: fillWidth,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(trackHeight / 2.0),
                        gradient: (!useLiquidEffects || resolvedActiveColor != mediaGold)
                            ? null
                            : LinearGradient(
                                colors: [resolvedActiveColor, const Color(0xFFFFD970)],
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                              ),
                        color: resolvedActiveColor,
                        boxShadow: [
                          BoxShadow(
                            color: resolvedActiveColor.withOpacity(_isDragging ? 0.4 : 0.15),
                            blurRadius: _isDragging ? 6 : 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 3. Sliding / Rubber-banding Seeker Thumb
                  AnimatedPositioned(
                    duration: duration,
                    curve: curve,
                    left: thumbLeft,
                    child: Container(
                      width: thumbSize,
                      height: thumbSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        border: Border.all(
                          color: resolvedThumbColor,
                          width: _isDragging ? 4.0 : 3.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.35),
                            blurRadius: _isDragging ? 8 : 4,
                            offset: const Offset(0, 2),
                          ),
                          if (_isDragging)
                            BoxShadow(
                              color: resolvedThumbColor.withOpacity(0.5),
                              blurRadius: 10,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (!widget.showTimeLabels) {
      return sliderWidget;
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: sliderWidget,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatMediaDuration(widget.position), style: timeStyle),
              Text(formatMediaDuration(widget.duration), style: timeStyle),
            ],
          ),
        ),
      ],
    );
  }
}
