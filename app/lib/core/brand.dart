import 'package:flutter/material.dart';

import 'theme.dart';

/// Tickr brand constants and logo lockup.
///
/// Identity: sharp, minimal, "Bloomberg-terminal cool". The mark is an
/// ascending trio of bars capped by an up-triangle — price, rising.
abstract final class Brand {
  static const String name = 'Tickr';
  static const String slogan = 'Trade. Compete. Rise.';
  static const String tagline = 'A live market. Fake money. Real glory.';

  /// Signature electric cyan-blue.
  static const Color primary = Color(0xFF3DE1C4);
  static const Color primaryAlt = Color(0xFF4DA3FF);

  static const LinearGradient gradient = LinearGradient(
    begin: Alignment.bottomLeft,
    end: Alignment.topRight,
    colors: [primaryAlt, primary],
  );
}

/// The Tickr logo mark: three ascending bars rising into a triangle apex.
class TickrMark extends StatelessWidget {
  const TickrMark({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _TickrMarkPainter()),
    );
  }
}

class _TickrMarkPainter extends CustomPainter {
  // Mark geometry matches the app icon (a breakout arrow, up and to the right),
  // authored in a 1024 space and fitted into the widget box.
  static const _bx0 = 250.0, _by0 = 300.0, _bx1 = 792.0, _by1 = 700.0;

  @override
  void paint(Canvas canvas, Size size) {
    const bw = _bx1 - _bx0, bh = _by1 - _by0;
    const pad = 0.06;
    final avail = size.shortestSide * (1 - 2 * pad);
    final scale = avail / (bw > bh ? bw : bh);
    final dx = (size.width - bw * scale) / 2 - _bx0 * scale;
    final dy = (size.height - bh * scale) / 2 - _by0 * scale;
    double x(double v) => v * scale + dx;
    double y(double v) => v * scale + dy;

    final paint = Paint()
      ..shader = Brand.gradient.createShader(Offset.zero & size)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 94 * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final line = Path()
      ..moveTo(x(250), y(700))
      ..lineTo(x(468), y(548))
      ..lineTo(x(792), y(300));
    final head = Path()
      ..moveTo(x(646), y(300))
      ..lineTo(x(792), y(300))
      ..lineTo(x(792), y(446));
    canvas
      ..drawPath(line, paint)
      ..drawPath(head, paint);
  }

  @override
  bool shouldRepaint(_) => false;
}

/// Full horizontal logo lockup: mark + "Tickr" wordmark.
class TickrLogo extends StatelessWidget {
  const TickrLogo({super.key, this.height = 40, this.showWordmark = true});

  final double height;
  final bool showWordmark;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TickrMark(size: height),
        if (showWordmark) ...[
          SizedBox(width: height * 0.28),
          ShaderMask(
            shaderCallback: (bounds) => Brand.gradient.createShader(bounds),
            child: Text(
              'Tickr',
              style: TextStyle(
                fontSize: height * 0.82,
                fontWeight: FontWeight.w900,
                letterSpacing: -1,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A consistent app bar carrying the Tickr mark next to the section title —
/// keeps the brand present on every screen.
AppBar tickrAppBar({
  required String title,
  List<Widget>? actions,
  PreferredSizeWidget? bottom,
}) {
  return AppBar(
    titleSpacing: 12,
    title: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const TickrMark(size: 24),
        const SizedBox(width: 10),
        Text(title),
      ],
    ),
    actions: actions,
    bottom: bottom,
  );
}

/// The animated splash / sign-in hero: logo + slogan with a subtle live feel.
class TickrHero extends StatelessWidget {
  const TickrHero({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const TickrLogo(height: 56),
        const SizedBox(height: 14),
        Text(
          Brand.slogan.toUpperCase(),
          style: TextStyle(
            fontSize: 13,
            letterSpacing: 3,
            fontWeight: FontWeight.w600,
            color: AppTheme.up,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          Brand.tagline,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
        ),
      ],
    );
  }
}
