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
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final shader = Brand.gradient.createShader(Offset.zero & size);
    final bar = Paint()
      ..shader = shader
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.11;

    // Three ascending bars.
    final baseY = h * 0.86;
    final xs = [w * 0.2, w * 0.4, w * 0.6];
    final tops = [h * 0.62, h * 0.44, h * 0.26];
    for (var i = 0; i < 3; i++) {
      canvas.drawLine(Offset(xs[i], baseY), Offset(xs[i], tops[i]), bar);
    }

    // Rising triangle apex (the "tick" up).
    final apex = Path()
      ..moveTo(w * 0.52, h * 0.36)
      ..lineTo(w * 0.86, h * 0.14)
      ..lineTo(w * 0.86, h * 0.42)
      ..close();
    canvas.drawPath(apex, Paint()..shader = shader);
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
