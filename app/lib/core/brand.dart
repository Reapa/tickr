import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets/nav_actions.dart';

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
  // Two candlesticks (a down candle then a taller up candle), authored in a
  // 50×52 space and fitted into the widget box. Uses the app's up/down colors
  // so the brand speaks the same language as the market.
  @override
  void paint(Canvas canvas, Size size) {
    const bx0 = 9.0, by0 = 4.0, bx1 = 41.0, by1 = 46.0;
    const bw = bx1 - bx0, bh = by1 - by0;
    const pad = 0.08;
    final avail = size.shortestSide * (1 - 2 * pad);
    final scale = avail / (bw > bh ? bw : bh);
    final dx = (size.width - bw * scale) / 2 - bx0 * scale;
    final dy = (size.height - bh * scale) / 2 - by0 * scale;
    double x(double v) => v * scale + dx;
    double y(double v) => v * scale + dy;

    void candle(Color c, double cx, double wickTop, double wickBot,
        double bodyTop, double bodyBot) {
      canvas.drawLine(
        Offset(x(cx), y(wickTop)),
        Offset(x(cx), y(wickBot)),
        Paint()
          ..color = c
          ..strokeWidth = 3 * scale
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x(cx - 6), y(bodyTop), x(cx + 6), y(bodyBot)),
          Radius.circular(3 * scale),
        ),
        Paint()..color = c,
      );
    }

    candle(AppTheme.down, 15, 8, 46, 16, 36); // down (red)
    candle(AppTheme.up, 35, 4, 44, 12, 36); // up (green), taller
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
/// keeps the brand present on every screen. The persistent Friends / Store /
/// Sign-out actions are appended on the right (after any [actions]) so they're
/// reachable from every main screen; pass `globalActions: false` to omit them.
AppBar tickrAppBar({
  required String title,
  List<Widget> actions = const [],
  PreferredSizeWidget? bottom,
  bool globalActions = true,
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
    actions: [
      ...actions,
      if (globalActions) const TickrActions(),
    ],
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
