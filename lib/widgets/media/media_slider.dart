import 'package:flutter/material.dart';

import 'media_colors.dart';
import 'media_utils.dart';

class MediaSlider extends StatelessWidget {
  const MediaSlider({
    super.key,
    required this.position,
    required this.duration,
    required this.onChanged,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onChanged;

  @override
  Widget build(BuildContext context) {
    final total = duration.inMilliseconds;
    final current = total <= 0
        ? 0.0
        : position.inMilliseconds.clamp(0, total).toDouble();
    final timeStyle = TextStyle(
      color: mediaMuted,
      fontSize: 12,
      fontWeight: FontWeight.w700,
    );

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3.0,
            activeTrackColor: mediaGold,
            inactiveTrackColor: Colors.white24,
            thumbColor: mediaGold,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
            overlayColor: mediaGold.withValues(alpha: 0.12),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 18.0),
          ),
          child: Slider(
            value: current,
            min: 0,
            max: total <= 0 ? 1 : total.toDouble(),
            onChanged: total <= 0
                ? null
                : (value) => onChanged(Duration(milliseconds: value.round())),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatMediaDuration(position), style: timeStyle),
              Text(formatMediaDuration(duration), style: timeStyle),
            ],
          ),
        ),
      ],
    );
  }
}
