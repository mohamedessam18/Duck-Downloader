import 'package:flutter/material.dart';

import '../theme/duck_theme.dart';

class DuckMark extends StatelessWidget {
  const DuckMark({super.key, this.size = 120});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = DuckColors.of(context);
    return CustomPaint(
      size: Size.square(size),
      painter: _DuckMarkPainter(
        gold: colors.gold,
        warmGold: colors.warmGold,
      ),
    );
  }
}

class _DuckMarkPainter extends CustomPainter {
  _DuckMarkPainter({required this.gold, required this.warmGold});

  final Color gold;
  final Color warmGold;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.42;

    final circlePaint = Paint()
      ..color = gold.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, circlePaint);

    final bodyPaint = Paint()..color = gold;
    final beakPaint = Paint()..color = warmGold;

    final body = Path()
      ..addOval(Rect.fromCenter(
        center: Offset(center.dx, center.dy + size.height * 0.04),
        width: size.width * 0.52,
        height: size.height * 0.44,
      ));
    canvas.drawPath(body, bodyPaint);

    canvas.drawCircle(
      Offset(center.dx - size.width * 0.08, center.dy - size.height * 0.08),
      size.width * 0.09,
      bodyPaint,
    );

    canvas.drawPath(
      Path()
        ..moveTo(center.dx + size.width * 0.08, center.dy - size.height * 0.02)
        ..lineTo(center.dx + size.width * 0.22, center.dy)
        ..lineTo(center.dx + size.width * 0.08, center.dy + size.height * 0.02)
        ..close(),
      beakPaint,
    );

    final arrowPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.06
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final arrowTop = center.dy + size.height * 0.18;
    canvas.drawLine(
      Offset(center.dx, arrowTop),
      Offset(center.dx, arrowTop + size.height * 0.18),
      arrowPaint,
    );
    canvas.drawLine(
      Offset(center.dx, arrowTop + size.height * 0.18),
      Offset(center.dx - size.width * 0.08, arrowTop + size.height * 0.1),
      arrowPaint,
    );
    canvas.drawLine(
      Offset(center.dx, arrowTop + size.height * 0.18),
      Offset(center.dx + size.width * 0.08, arrowTop + size.height * 0.1),
      arrowPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _DuckMarkPainter oldDelegate) {
    return oldDelegate.gold != gold || oldDelegate.warmGold != warmGold;
  }
}
