/// Shared seascape rendering for the fishery.
///
/// Everything that draws water in this feature draws it from here, so the
/// harbour, the deck between casts and the fight are visibly the same ocean
/// rather than three unrelated blue rectangles. The primitives are deliberately
/// cheap — sampled sine sums and flat fills — because this runs on a web canvas
/// at 60fps behind a live simulation.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The look of one stretch of water. Grading the fight (calm water turning
/// angry as the line loads up) is a lerp between two of these rather than a
/// red overlay, which keeps the foam and the light believable.
@immutable
class SeaPalette {
  const SeaPalette({
    required this.skyTop,
    required this.skyHorizon,
    required this.glow,
    required this.surface,
    required this.deep,
    required this.foam,
  });

  final Color skyTop;
  final Color skyHorizon;

  /// The low sun's bloom. Also lights the shafts under the surface.
  final Color glow;
  final Color surface;
  final Color deep;
  final Color foam;

  /// Dusk in the harbour: cold, still, on-brand.
  static const calm = SeaPalette(
    skyTop: Color(0xFF05080F),
    skyHorizon: Color(0xFF0E3550),
    glow: Color(0xFF3DE1C4),
    surface: Color(0xFF11557E),
    deep: Color(0xFF03121E),
    foam: Color(0xFFBFE9F5),
  );

  /// Open water with something on the line.
  static const open = SeaPalette(
    skyTop: Color(0xFF04070D),
    skyHorizon: Color(0xFF0B2C46),
    glow: Color(0xFF35C9DC),
    surface: Color(0xFF0C4568),
    deep: Color(0xFF010A11),
    foam: Color(0xFFCDEDF7),
  );

  /// Over the top of the band: the whole scene warms and the swell gets short
  /// and mean. This is the tell you can read without looking at the gauge.
  static const strained = SeaPalette(
    skyTop: Color(0xFF150609),
    skyHorizon: Color(0xFF5E2711),
    glow: Color(0xFFFF9351),
    surface: Color(0xFF66300F),
    deep: Color(0xFF0D0406),
    foam: Color(0xFFFFDCC2),
  );

  /// The fish won and the line is gone.
  static const lost = SeaPalette(
    skyTop: Color(0xFF0C0410),
    skyHorizon: Color(0xFF2B1030),
    glow: Color(0xFF8E5A9E),
    surface: Color(0xFF2A1734),
    deep: Color(0xFF060209),
    foam: Color(0xFFCBB6D6),
  );

  static SeaPalette lerp(SeaPalette a, SeaPalette b, double t) {
    final k = t.clamp(0.0, 1.0);
    return SeaPalette(
      skyTop: Color.lerp(a.skyTop, b.skyTop, k)!,
      skyHorizon: Color.lerp(a.skyHorizon, b.skyHorizon, k)!,
      glow: Color.lerp(a.glow, b.glow, k)!,
      surface: Color.lerp(a.surface, b.surface, k)!,
      deep: Color.lerp(a.deep, b.deep, k)!,
      foam: Color.lerp(a.foam, b.foam, k)!,
    );
  }
}

/// Height of the water at [x], in pixels off the rest line.
///
/// Three harmonics that do not share a period. One sine reads as a cartoon;
/// this reads as swell, and costs the same.
double swellAt(
  double x,
  double t, {
  required double amp,
  required double len,
  required double speed,
  double phase = 0,
}) =>
    math.sin(x / len + t * speed + phase) * amp +
    math.sin(x / (len * 0.47) - t * speed * 1.7 + phase * 2.3) * amp * 0.42 +
    math.sin(x / (len * 0.19) + t * speed * 2.9 + phase * 4.1) * amp * 0.16;

/// Deterministic 0..1 noise, for breaking up anything that would otherwise be
/// evenly spaced. Cheaper than carrying a seeded Random through the painters.
double _hash(double x) {
  final v = math.sin(x * 12.9898) * 43758.5453;
  return (v - v.floorToDouble()).abs();
}

/// One band of water, drawn as a filled crest line down to the bottom of the
/// frame. Bands are painted back to front, so a near band occludes whatever was
/// swimming behind it — which is the whole illusion of depth here.
@immutable
class SeaBand {
  const SeaBand({
    required this.rest,
    required this.amp,
    required this.len,
    required this.speed,
    required this.phase,
    required this.color,
    this.foam = 0,
  });

  /// Where its rest line sits, as a fraction of the frame height.
  final double rest;
  final double amp;
  final double len;
  final double speed;
  final double phase;
  final Color color;

  /// 0..1 — how much white water breaks along its crests.
  final double foam;

  double yAt(double x, double t, Size size, {double chop = 0}) =>
      size.height * rest +
      swellAt(x, t,
          amp: amp * (1 + chop * 1.6),
          len: len * (1 - chop * 0.35),
          speed: speed * (1 + chop * 0.9),
          phase: phase);

  void paint(Canvas canvas, Size size, double t,
      {double chop = 0, Color? foamColor}) {
    final path = Path()..moveTo(-4, yAt(-4, t, size, chop: chop));
    for (double x = -4; x <= size.width + 8; x += 6) {
      path.lineTo(x, yAt(x, t, size, chop: chop));
    }
    path
      ..lineTo(size.width + 8, size.height + 8)
      ..lineTo(-4, size.height + 8)
      ..close();
    canvas.drawPath(path, Paint()..color = color);

    if (foam <= 0 || foamColor == null) return;
    // White water only at genuine crest peaks, and broken up per-x. Evenly
    // spaced flecks along a whole crest do not read as spray — they read as a
    // dashed line ruled across the sea, which is exactly what they looked like.
    final crest = Paint();
    for (double x = 0; x <= size.width; x += 7) {
      final y = yAt(x, t, size, chop: chop);
      if ((size.height * rest) - y < amp * 0.70) continue;
      final r = _hash(x + phase * 97);
      if (r > 0.5) continue;
      crest.color = foamColor.withValues(alpha: 0.30 * foam * (0.4 + r));
      canvas.drawOval(
        Rect.fromCenter(
            center: Offset(x, y), width: 3.5 + r * 9, height: 1.3),
        crest,
      );
    }
  }
}

/// Sky, horizon haze and the low sun. [sunX] is a fraction of the width.
void paintSky(
  Canvas canvas,
  Size size,
  SeaPalette p, {
  required double horizonY,
  required double t,
  double sunX = 0.72,
  double stars = 1,
}) {
  final sky = Rect.fromLTRB(0, 0, size.width, horizonY + 1);
  canvas.drawRect(
    sky,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [p.skyTop, p.skyHorizon],
      ).createShader(sky),
  );

  if (stars > 0) {
    final dot = Paint();
    for (final s in _stars) {
      final twinkle = 0.55 + 0.45 * math.sin(t * 1.7 + s.dx * 40);
      dot.color = Colors.white
          .withValues(alpha: 0.5 * stars * twinkle * (1 - s.dy * 1.5).clamp(0.0, 1.0));
      canvas.drawCircle(
          Offset(s.dx * size.width, s.dy * horizonY), 0.9, dot);
    }
  }

  // The sun sitting on the horizon, mostly bloom. Drawn as three stacked
  // circles rather than a blur filter — a MaskFilter here costs more than the
  // rest of the frame put together on a web canvas.
  final sx = size.width * sunX;
  for (var i = 3; i >= 1; i--) {
    canvas.drawCircle(
      Offset(sx, horizonY),
      18.0 * i * i * 0.7,
      Paint()..color = p.glow.withValues(alpha: 0.05 / i),
    );
  }
  canvas.drawCircle(
      Offset(sx, horizonY), 11, Paint()..color = p.glow.withValues(alpha: 0.5));

  // Low cloud streaks. Flat, wide and barely there — enough to stop the sky
  // reading as a gradient swatch.
  final cloud = Paint()..color = p.skyTop.withValues(alpha: 0.55);
  for (var i = 0; i < 3; i++) {
    final y = horizonY * (0.42 + i * 0.16);
    final drift = (t * (3 + i * 2)) % (size.width + 260) - 130;
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(drift, y), width: 170 + i * 60, height: 5.0 + i),
      cloud,
    );
  }

  // Haze where sea meets sky, so the join is atmospheric rather than a seam.
  final haze = Rect.fromLTRB(0, horizonY - 14, size.width, horizonY + 8);
  canvas.drawRect(
    haze,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          p.glow.withValues(alpha: 0),
          p.glow.withValues(alpha: 0.16),
          p.glow.withValues(alpha: 0),
        ],
      ).createShader(haze),
  );
}

/// The body of water below [horizonY]: a depth gradient plus the shafts of
/// light coming down through it.
void paintWaterBody(
  Canvas canvas,
  Size size,
  SeaPalette p, {
  required double horizonY,
  required double t,
  double sunX = 0.72,
  double shafts = 1,
}) {
  final water = Rect.fromLTRB(0, horizonY, size.width, size.height);
  canvas.drawRect(
    water,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [p.surface, p.deep],
        stops: const [0.0, 0.85],
      ).createShader(water),
  );

  if (shafts <= 0) return;
  canvas.save();
  canvas.clipRect(water);
  final sx = size.width * sunX;
  for (var i = 0; i < 5; i++) {
    final sway = math.sin(t * 0.28 + i * 1.9) * 26;
    final top = sx + (i - 2) * 34 + sway * 0.3;
    final spread = 26.0 + i * 9;
    final bottom = sx + (i - 2) * 150 + sway;
    final path = Path()
      ..moveTo(top - 5, horizonY)
      ..lineTo(top + 5, horizonY)
      ..lineTo(bottom + spread, size.height)
      ..lineTo(bottom - spread, size.height)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            p.glow.withValues(alpha: 0.10 * shafts),
            p.glow.withValues(alpha: 0),
          ],
        ).createShader(water),
    );
  }
  canvas.restore();
}

/// A moored boat in silhouette, riding the swell. [cx] and [waterY] are pixels.
void paintBoat(
  Canvas canvas,
  Size size, {
  required double cx,
  required double waterY,
  required double scale,
  required double t,
  required Color hull,
  required Color light,
}) {
  final lift = math.sin(t * 0.9) * 3 * scale;
  final roll = math.sin(t * 0.62 + 0.6) * 0.035;
  canvas.save();
  canvas.translate(cx, waterY + lift);
  canvas.rotate(roll);

  final w = 130.0 * scale;
  final h = 26.0 * scale;
  final paint = Paint()..color = hull;

  // Hull: a flat sheer line with a raked bow.
  final hullPath = Path()
    ..moveTo(-w * 0.5, -h * 0.55)
    ..lineTo(w * 0.42, -h * 0.75)
    ..quadraticBezierTo(w * 0.56, -h * 0.55, w * 0.44, h * 0.10)
    ..quadraticBezierTo(w * 0.10, h * 0.62, -w * 0.40, h * 0.30)
    ..quadraticBezierTo(-w * 0.52, h * 0.10, -w * 0.5, -h * 0.55)
    ..close();
  canvas.drawPath(hullPath, paint);

  // Wheelhouse and mast.
  canvas.drawRect(
      Rect.fromLTWH(-w * 0.26, -h * 2.05, w * 0.30, h * 1.5), paint);
  canvas.drawRect(
      Rect.fromLTWH(-w * 0.03, -h * 3.6, w * 0.028, h * 3.0), paint);
  // Boom, angled aft — the outline that says "working boat".
  canvas.drawPath(
    Path()
      ..moveTo(-w * 0.016, -h * 3.5)
      ..lineTo(-w * 0.40, -h * 1.6)
      ..lineTo(-w * 0.36, -h * 1.5)
      ..lineTo(-w * 0.002, -h * 3.3)
      ..close(),
    paint,
  );

  // Masthead light, and the smear of it on the water.
  final lamp = Offset(-w * 0.016, -h * 3.7);
  canvas.drawCircle(lamp, 1.8 * scale, Paint()..color = light);
  canvas.drawCircle(
      lamp, 5.5 * scale, Paint()..color = light.withValues(alpha: 0.13));
  canvas.drawOval(
    Rect.fromCenter(
        center: Offset(0, h * 0.75), width: w * 0.9, height: h * 0.34),
    Paint()..color = light.withValues(alpha: 0.10),
  );

  canvas.restore();
}

/// Gulls, because an empty sky reads as a loading screen.
void paintGulls(Canvas canvas, Size size, double t, Color color) {
  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.3;
  for (var i = 0; i < 3; i++) {
    final x = ((t * (11 + i * 4) + i * 190) % (size.width + 120)) - 60;
    final y = size.height * (0.14 + i * 0.07) + math.sin(t * 0.8 + i) * 4;
    final flap = math.sin(t * 5.5 + i * 2.1) * 2.6;
    final s = 5.0 - i * 0.8;
    canvas.drawPath(
      Path()
        ..moveTo(x - s * 2, y + flap)
        ..quadraticBezierTo(x - s, y - s * 0.7, x, y)
        ..quadraticBezierTo(x + s, y - s * 0.7, x + s * 2, y + flap),
      paint,
    );
  }
}

/// Darkens the corners so the eye lands in the middle of the scene.
void paintVignette(Canvas canvas, Size size, {double strength = 0.5}) {
  final rect = Offset.zero & size;
  canvas.drawRect(
    rect,
    Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 0.95,
        colors: [
          Colors.transparent,
          Colors.black.withValues(alpha: strength),
        ],
        stops: const [0.55, 1.0],
      ).createShader(rect),
  );
}

/// Fixed star field, in fractional coordinates. Seeded so it does not crawl
/// between rebuilds.
final List<Offset> _stars = () {
  final rng = math.Random(31337);
  return List<Offset>.generate(
      44, (_) => Offset(rng.nextDouble(), rng.nextDouble() * 0.8));
}();

// ---------------------------------------------------------------------------
// The idle frame
// ---------------------------------------------------------------------------

/// The living seascape behind the harbour and the deck. Same water as the
/// fight, minus the fight.
class SeaFrame extends StatefulWidget {
  const SeaFrame({
    super.key,
    required this.height,
    required this.child,
    this.palette = SeaPalette.calm,
    this.showBoat = true,
  });

  final double height;
  final Widget child;
  final SeaPalette palette;
  final bool showBoat;

  @override
  State<SeaFrame> createState() => _SeaFrameState();
}

class _SeaFrameState extends State<SeaFrame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 120),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, _) => CustomPaint(
                  painter: _HarbourPainter(
                    t: _c.value * 120,
                    palette: widget.palette,
                    showBoat: widget.showBoat,
                  ),
                ),
              ),
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}

class _HarbourPainter extends CustomPainter {
  _HarbourPainter({
    required this.t,
    required this.palette,
    required this.showBoat,
  });

  final double t;
  final SeaPalette palette;
  final bool showBoat;

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    final horizon = size.height * 0.44;

    paintSky(canvas, size, p, horizonY: horizon, t: t, sunX: 0.74);
    paintGulls(canvas, size, t, Colors.white.withValues(alpha: 0.22));
    paintWaterBody(canvas, size, p,
        horizonY: horizon, t: t, sunX: 0.74, shafts: 0.5);

    // Far band first, then the boat between the bands, then the near band over
    // its waterline — which is what makes the hull sit *in* the water.
    SeaBand(
      rest: 0.52,
      amp: 2.2,
      len: 34,
      speed: 0.5,
      phase: 0,
      color: Color.lerp(p.surface, p.deep, 0.30)!,
    ).paint(canvas, size, t);

    if (showBoat) {
      paintBoat(
        canvas,
        size,
        cx: size.width * 0.30,
        waterY: size.height * 0.60,
        scale: math.min(1.0, size.width / 420),
        t: t,
        hull: Color.lerp(p.deep, Colors.black, 0.45)!,
        light: p.glow,
      );
    }

    SeaBand(
      rest: 0.64,
      amp: 4.0,
      len: 46,
      speed: 0.72,
      phase: 1.4,
      color: Color.lerp(p.surface, p.deep, 0.55)!,
      foam: 0.4,
    ).paint(canvas, size, t, foamColor: p.foam);
    SeaBand(
      rest: 0.82,
      amp: 6.5,
      len: 62,
      speed: 0.95,
      phase: 2.9,
      color: Color.lerp(p.surface, p.deep, 0.78)!,
      foam: 0.6,
    ).paint(canvas, size, t, foamColor: p.foam);

    paintVignette(canvas, size, strength: 0.42);
  }

  @override
  bool shouldRepaint(_HarbourPainter old) => true;
}
