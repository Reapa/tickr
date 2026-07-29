/// The six places you can fish, as places.
///
/// Each spot in the server's catalog gets a biome here, keyed by its code. A
/// biome owns everything that makes one stretch of water not another one: how
/// the light falls, how far you can see through it, what the bottom is (or
/// whether there is one), and what lives there.
///
/// This is deliberately data-plus-a-painter rather than six copies of the fight
/// scene. The scene stays one pipeline; the biome decides what goes in it.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'sea.dart';

/// What the backdrop is made of. The fight scene asks the biome to paint into
/// two slots — behind the fish and in front of it — so structure can sit at a
/// believable depth rather than always being wallpaper.
enum BackdropSlot { far, near }

@immutable
class Biome {
  const Biome({
    required this.code,
    required this.name,
    required this.palette,
    required this.strained,
    this.horizon = 0.22,
    this.surface = 0.40,
    this.sunX = 0.78,
    this.stars = 1.0,
    this.shafts = 1.0,
    this.glitter = 1.0,
    this.motes = 1.0,
    this.clarity = 1.0,
    this.gulls = false,
    this.bottom = 0,
    this.aurora = 0,
    this.iceCeiling = false,
    this.bioluminescence = 0,
  });

  final String code;
  final String name;

  /// The resting look, and what it grades toward as the line loads up.
  final SeaPalette palette;
  final SeaPalette strained;

  /// Where the sky ends and where the near waterline sits, as fractions of the
  /// frame. The Trench pushes both up; there is no sky worth showing down there.
  final double horizon;
  final double surface;

  final double sunX;

  /// Scales for the shared atmospheric effects. Zero switches one off entirely.
  final double stars;
  final double shafts;
  final double glitter;
  final double motes;

  /// How far you can see through the water, 0..1. Drives how much of the fish
  /// is readable at depth — the Trench's whole character is a low number here.
  final double clarity;

  final bool gulls;

  /// Where the seabed sits as a fraction of the frame, or 0 for water with no
  /// bottom in shot. Open Water and the Canyon are deliberately bottomless.
  final double bottom;

  final double aurora;
  final bool iceCeiling;

  /// How much of the light in the water comes from living things rather than
  /// the sun.
  final double bioluminescence;

  static const Map<String, Biome> _all = {
    'harbour': _harbour,
    'reef': _reef,
    'open_water': _openWater,
    'canyon': _canyon,
    'trench': _trench,
    'polar': _polar,
  };

  /// Falls back to open water for a spot code this build has never heard of —
  /// the catalog is server-side and can gain a row before the app ships.
  static Biome of(String? code) => _all[code] ?? _openWater;

  static const _harbour = Biome(
    code: 'harbour',
    name: 'The Harbour',
    palette: SeaPalette(
      skyTop: Color(0xFF06090F),
      skyHorizon: Color(0xFF14384F),
      glow: Color(0xFFFFC94D), // sodium lamps on the wall, not a sunset
      surface: Color(0xFF16607F),
      deep: Color(0xFF06202B),
      foam: Color(0xFFCFEAF2),
    ),
    strained: SeaPalette.strained,
    sunX: 0.84,
    shafts: 0.4,
    glitter: 0.7,
    clarity: 0.72, // silty, stirred up by boats
    gulls: true,
    // Bottoms sit above the gunwale sweep, or the boat simply hides them.
    bottom: 0.84, // shallow enough to see the bed
  );

  static const _reef = Biome(
    code: 'reef',
    name: 'The Reef',
    palette: SeaPalette(
      skyTop: Color(0xFF071A2C),
      skyHorizon: Color(0xFF2E7E96),
      glow: Color(0xFF8FE8D8),
      surface: Color(0xFF1D8FA6),
      deep: Color(0xFF06414F),
      foam: Color(0xFFDFFAF7),
    ),
    strained: SeaPalette(
      skyTop: Color(0xFF1A0A08),
      skyHorizon: Color(0xFF7A3A18),
      glow: Color(0xFFFFB070),
      surface: Color(0xFF8A4A1E),
      deep: Color(0xFF20100A),
      foam: Color(0xFFFFE6D0),
    ),
    horizon: 0.20,
    surface: 0.36,
    stars: 0.3,
    shafts: 1.5, // clear shallow water, hard sunbeams
    clarity: 1.0,
    gulls: true,
    bottom: 0.78,
  );

  static const _openWater = Biome(
    code: 'open_water',
    name: 'Open Water',
    palette: SeaPalette.open,
    strained: SeaPalette.strained,
    clarity: 0.9,
    shafts: 1.0,
    gulls: true,
    bottom: 0, // no bottom, and that is the point
  );

  static const _canyon = Biome(
    code: 'canyon',
    name: 'The Canyon',
    palette: SeaPalette(
      skyTop: Color(0xFF03060B),
      skyHorizon: Color(0xFF0A2438),
      glow: Color(0xFF2E9FC4),
      surface: Color(0xFF0A3A58),
      deep: Color(0xFF000407),
      foam: Color(0xFFBCDCE8),
    ),
    strained: SeaPalette.strained,
    horizon: 0.20,
    surface: 0.38,
    shafts: 0.75,
    clarity: 0.78,
    motes: 1.3,
    bottom: 0, // the shelf is drawn as structure; beyond it, nothing
  );

  static const _trench = Biome(
    code: 'trench',
    name: 'The Trench',
    palette: SeaPalette(
      skyTop: Color(0xFF01020A),
      skyHorizon: Color(0xFF050C1C),
      glow: Color(0xFF3FE0C0),
      surface: Color(0xFF04121F),
      deep: Color(0xFF000103),
      foam: Color(0xFF7FB8C8),
    ),
    strained: SeaPalette(
      skyTop: Color(0xFF120309),
      skyHorizon: Color(0xFF2E0A14),
      glow: Color(0xFFFF6A7A),
      surface: Color(0xFF23070F),
      deep: Color(0xFF040001),
      foam: Color(0xFFE0A0AC),
    ),
    horizon: 0.10,
    surface: 0.20, // barely any surface: you are deep, and it is far above
    stars: 0,
    shafts: 0.12,
    glitter: 0.15,
    motes: 2.2, // marine snow, thick
    clarity: 0.30, // you mostly do not see it coming
    bioluminescence: 1.0,
    bottom: 0,
  );

  static const _polar = Biome(
    code: 'polar',
    name: 'The Ice Shelf',
    palette: SeaPalette(
      skyTop: Color(0xFF040A16),
      skyHorizon: Color(0xFF23516E),
      glow: Color(0xFFCFE9FF),
      surface: Color(0xFF175A79),
      deep: Color(0xFF03151F),
      foam: Color(0xFFF2FBFF),
    ),
    strained: SeaPalette(
      skyTop: Color(0xFF16060B),
      skyHorizon: Color(0xFF5E2418),
      glow: Color(0xFFFFC0A0),
      surface: Color(0xFF6B3020),
      deep: Color(0xFF120507),
      foam: Color(0xFFFFEDE4),
    ),
    horizon: 0.24,
    surface: 0.42,
    sunX: 0.30,
    stars: 1.0,
    shafts: 0.5,
    clarity: 0.95, // brutally clear
    aurora: 1.0,
    iceCeiling: true,
    bottom: 0,
  );

  /// Everything that belongs behind the fish: the shelf wall, the bed, the
  /// coral heads. Painted inside the water column's clip.
  void paintFar(Canvas canvas, Size size, double t, double chop) {
    switch (code) {
      case 'harbour':
        _paintHarbourBed(canvas, size, t);
      case 'reef':
        _paintReef(canvas, size, t, near: false);
      case 'canyon':
        _paintCanyonWall(canvas, size, t);
      case 'trench':
        _paintTrenchLife(canvas, size, t);
      case 'polar':
        _paintBergsBelow(canvas, size, t);
      default:
        _paintBaitBall(canvas, size, t);
    }
  }

  /// Foreground structure, painted over the fish so it can swim behind things.
  void paintNear(Canvas canvas, Size size, double t, double chop) {
    switch (code) {
      case 'harbour':
        _paintPilings(canvas, size, t);
      case 'reef':
        _paintReef(canvas, size, t, near: true);
      default:
        break;
    }
  }

  /// Above the waterline: what is on the horizon.
  void paintSkyline(Canvas canvas, Size size, double t) {
    final horizonY = size.height * horizon;
    switch (code) {
      case 'harbour':
        _paintHarbourWall(canvas, size, horizonY);
      case 'polar':
        _paintBergs(canvas, size, horizonY, t);
      case 'reef':
        _paintHeadland(canvas, size, horizonY);
      default:
        break;
    }
  }

  // -- harbour ---------------------------------------------------------------

  void _paintHarbourWall(Canvas canvas, Size size, double horizonY) {
    final wall = Paint()..color = const Color(0xFF04080D);
    // A stone arm running out across the back of the frame, with lamps on it.
    final top = horizonY - size.height * 0.055;
    canvas.drawRect(Rect.fromLTRB(0, top, size.width * 0.62, horizonY), wall);
    canvas.drawRect(
      Rect.fromLTRB(size.width * 0.56, top - size.height * 0.03,
          size.width * 0.62, horizonY),
      wall,
    );
    for (var i = 0; i < 4; i++) {
      final x = size.width * (0.07 + i * 0.15);
      canvas.drawCircle(
          Offset(x, top - 3), 1.8, Paint()..color = palette.glow);
      canvas.drawCircle(Offset(x, top - 3), 7,
          Paint()..color = palette.glow.withValues(alpha: 0.14));
      // The lamp's reflection, smeared down the water below it.
      canvas.drawRect(
        Rect.fromLTWH(x - 1.5, horizonY, 3, size.height * 0.16),
        Paint()..color = palette.glow.withValues(alpha: 0.07),
      );
    }
  }

  void _paintHarbourBed(Canvas canvas, Size size, double t) {
    if (bottom <= 0) return;
    final y = size.height * bottom;
    canvas.drawPath(
      Path()
        ..moveTo(0, size.height)
        ..lineTo(0, y + 6)
        ..quadraticBezierTo(size.width * 0.3, y - 8, size.width * 0.6, y + 2)
        ..quadraticBezierTo(size.width * 0.85, y + 8, size.width, y - 4)
        ..lineTo(size.width, size.height)
        ..close(),
      Paint()..color = Color.lerp(palette.deep, Colors.black, 0.35)!,
    );
    // Junk on the bottom of every working harbour.
    final junk = Paint()..color = Colors.black.withValues(alpha: 0.5);
    canvas.drawOval(
        Rect.fromCenter(
            center: Offset(size.width * 0.22, y + 4), width: 34, height: 9),
        junk);
    canvas.drawRect(
        Rect.fromLTWH(size.width * 0.70, y - 6, 22, 8), junk);
  }

  void _paintPilings(Canvas canvas, Size size, double t) {
    // Weed-skirted posts marching out of frame, the nearest darkest. Each gets
    // a lit edge on the lamp side, or they read as flat bars rather than round
    // timber standing in water.
    for (var i = 0; i < 3; i++) {
      final x = size.width * (0.05 + i * 0.125);
      final w = 16.0 - i * 3.5;
      final top = size.height * surface - 10;
      canvas.drawRect(
        Rect.fromLTWH(x, top, w, size.height),
        Paint()..color = Color.lerp(Colors.black, palette.deep, 0.12 + i * 0.12)!,
      );
      canvas.drawRect(
        Rect.fromLTWH(x + w - 2.2, top, 2.2, size.height),
        Paint()..color = palette.glow.withValues(alpha: 0.13 - i * 0.03),
      );
      // A tide line of barnacles where the water usually sits.
      canvas.drawRect(
        Rect.fromLTWH(x, top + 16, w, 5),
        Paint()..color = palette.foam.withValues(alpha: 0.10),
      );

      // Weed: limp fronds hanging down and swaying, not spikes sticking out.
      final weed = Paint()
        ..color = const Color(0xFF0B2E22).withValues(alpha: 0.85 - i * 0.18)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (var j = 0; j < 9; j++) {
        final wy = size.height * (surface + 0.05) + j * 26;
        if (wy > size.height) break;
        final side = j.isEven ? -1.0 : 1.0;
        final sway = math.sin(t * 0.8 + j * 0.9 + i) * 5;
        final len = 22.0 + (j % 3) * 9;
        weed.strokeWidth = 3.5 - (j % 3) * 0.7;
        canvas.drawPath(
          Path()
            ..moveTo(x + w / 2, wy)
            ..quadraticBezierTo(
              x + w / 2 + side * 8 + sway,
              wy + len * 0.5,
              x + w / 2 + side * 6 + sway * 1.6,
              wy + len,
            ),
          weed,
        );
      }
    }
  }

  // -- reef ------------------------------------------------------------------

  void _paintHeadland(Canvas canvas, Size size, double horizonY) {
    canvas.drawPath(
      Path()
        ..moveTo(size.width * 0.62, horizonY)
        ..lineTo(size.width * 0.74, horizonY - size.height * 0.05)
        ..lineTo(size.width * 0.86, horizonY - size.height * 0.028)
        ..lineTo(size.width, horizonY - size.height * 0.06)
        ..lineTo(size.width, horizonY)
        ..close(),
      Paint()..color = const Color(0xFF05141C),
    );
  }

  void _paintReef(Canvas canvas, Size size, double t, {required bool near}) {
    final bedY = size.height * bottom;
    if (!near) {
      // Sand, and the coral heads standing on it.
      canvas.drawRect(
        Rect.fromLTRB(0, bedY, size.width, size.height),
        Paint()..color = const Color(0xFF16506B),
      );
      final head = Paint()..color = Color.lerp(palette.deep, Colors.black, 0.2)!;
      for (var i = 0; i < 5; i++) {
        final x = size.width * (0.10 + i * 0.19);
        final h = 26.0 + (i.isEven ? 16 : 0);
        canvas.drawOval(
          Rect.fromCenter(
              center: Offset(x, bedY - h * 0.3), width: 54 - i * 4, height: h),
          head,
        );
      }
      return;
    }
    // Foreground kelp, drawn over the fish so it can pass behind. Stipes are
    // built as tapered filled shapes with blades hanging off them — stroked
    // polylines with a little sway just read as rigid poles, which is what the
    // first pass looked like.
    for (var i = 0; i < 4; i++) {
      final x = size.width * (0.05 + i * 0.29);
      final topY = bedY * (0.34 + (i % 2) * 0.14);
      final lean = (i.isEven ? 1.0 : -1.0);
      final alpha = 0.92 - (i % 2) * 0.18;
      final stipe = Paint()
        ..color = const Color(0xFF07231F).withValues(alpha: alpha);
      final blade = Paint()
        ..color = const Color(0xFF0A2E26).withValues(alpha: alpha * 0.85);

      // Sample the stipe once; both the trunk and the blades hang off it.
      final pts = <Offset>[];
      const steps = 9;
      for (var s = 0; s <= steps; s++) {
        final k = s / steps; // 0 at the holdfast, 1 at the tip
        final y = size.height + 12 - (size.height + 12 - topY) * k;
        final sway = math.sin(t * 0.7 + i * 1.9 + k * 2.4) * 20 * k * k;
        pts.add(Offset(x + sway + lean * 14 * k * k, y));
      }
      // Trunk: a ribbon that narrows toward the tip.
      final left = <Offset>[];
      final right = <Offset>[];
      for (var s = 0; s <= steps; s++) {
        final half = 4.2 * (1 - s / steps) + 0.9;
        left.add(pts[s].translate(-half, 0));
        right.add(pts[s].translate(half, 0));
      }
      final trunk = Path()..moveTo(left.first.dx, left.first.dy);
      for (final o in left.skip(1)) {
        trunk.lineTo(o.dx, o.dy);
      }
      for (final o in right.reversed) {
        trunk.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(trunk..close(), stipe);

      // Blades, alternating sides, drooping with the current.
      for (var s = 2; s < steps; s++) {
        final side = s.isEven ? 1.0 : -1.0;
        final p = pts[s];
        final drift = math.sin(t * 0.9 + s + i) * 5;
        canvas.drawPath(
          Path()
            ..moveTo(p.dx, p.dy)
            ..quadraticBezierTo(p.dx + side * 22 + drift, p.dy + 4,
                p.dx + side * 34 + drift, p.dy + 22)
            ..quadraticBezierTo(p.dx + side * 20 + drift, p.dy + 12,
                p.dx, p.dy + 8)
            ..close(),
          blade,
        );
      }
    }
  }

  // -- canyon ----------------------------------------------------------------

  void _paintCanyonWall(Canvas canvas, Size size, double t) {
    // The void first: the far side of the frame goes to black, so the shelf has
    // something to drop away *into*. The eye reads the contrast as depth far
    // more strongly than any gradient of blue does.
    final void_ = Rect.fromLTRB(
        size.width * 0.30, size.height * 0.40, size.width, size.height);
    canvas.drawRect(
      void_,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.72)],
        ).createShader(void_),
    );

    // The shelf itself: a broad terrace on the left with a ragged edge that
    // falls off the bottom of the world.
    final wall = Path()
      ..moveTo(0, size.height + 8)
      ..lineTo(0, size.height * 0.40)
      ..lineTo(size.width * 0.13, size.height * 0.43)
      ..lineTo(size.width * 0.20, size.height * 0.49)
      ..lineTo(size.width * 0.19, size.height * 0.58)
      ..lineTo(size.width * 0.28, size.height * 0.63)
      ..lineTo(size.width * 0.33, size.height * 0.76)
      ..lineTo(size.width * 0.27, size.height * 0.90)
      ..lineTo(size.width * 0.31, size.height + 8)
      ..close();
    canvas.drawPath(
        wall, Paint()..color = Color.lerp(palette.deep, Colors.black, 0.75)!);

    // A rim light down the lip, from the surface far above and behind.
    canvas.drawPath(
      Path()
        ..moveTo(0, size.height * 0.40)
        ..lineTo(size.width * 0.13, size.height * 0.43)
        ..lineTo(size.width * 0.20, size.height * 0.49)
        ..lineTo(size.width * 0.19, size.height * 0.58)
        ..lineTo(size.width * 0.28, size.height * 0.63),
      Paint()
        ..color = palette.glow.withValues(alpha: 0.30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );
  }

  // -- trench ----------------------------------------------------------------

  void _paintTrenchLife(Canvas canvas, Size size, double t) {
    // Nothing structural down here — just things that glow, drifting.
    for (var i = 0; i < 14; i++) {
      final seed = i * 37.0;
      final x = (size.width * ((seed * 0.137) % 1.0) +
              math.sin(t * 0.20 + i) * 22) %
          size.width;
      final y = size.height *
          (surface + 0.12 + ((seed * 0.219) % 1.0) * 0.78);
      final pulse = 0.35 + 0.65 * math.sin(t * 1.1 + i * 1.7).abs();
      final r = 1.6 + (i % 3) * 1.4;
      canvas.drawCircle(Offset(x, y), r * 4,
          Paint()..color = palette.glow.withValues(alpha: 0.05 * pulse));
      canvas.drawCircle(Offset(x, y), r,
          Paint()..color = palette.glow.withValues(alpha: 0.55 * pulse));
    }
  }

  // -- polar -----------------------------------------------------------------

  void _paintBergs(Canvas canvas, Size size, double horizonY, double t) {
    if (aurora > 0) {
      // Curtains, drawn as soft vertical gradients that breathe.
      for (var i = 0; i < 3; i++) {
        final x = size.width * (0.14 + i * 0.30) +
            math.sin(t * 0.20 + i) * size.width * 0.05;
        final w = size.width * (0.16 + i * 0.05);
        final rect = Rect.fromLTWH(x - w / 2, 0, w, horizonY * 0.92);
        canvas.drawRect(
          rect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                const Color(0xFF35E39A).withValues(
                    alpha: 0.02 + 0.05 * (0.5 + 0.5 * math.sin(t * 0.5 + i))),
                const Color(0xFF35E39A).withValues(alpha: 0.14),
                Colors.transparent,
              ],
              stops: const [0.0, 0.55, 1.0],
            ).createShader(rect),
        );
      }
    }
    // Bergs on the horizon: hard flat tops, which is what reads as ice.
    final ice = Paint()..color = const Color(0xFF0B2C3E);
    canvas.drawPath(
      Path()
        ..moveTo(size.width * 0.02, horizonY)
        ..lineTo(size.width * 0.09, horizonY - size.height * 0.052)
        ..lineTo(size.width * 0.24, horizonY - size.height * 0.044)
        ..lineTo(size.width * 0.31, horizonY)
        ..close(),
      ice,
    );
    canvas.drawPath(
      Path()
        ..moveTo(size.width * 0.60, horizonY)
        ..lineTo(size.width * 0.68, horizonY - size.height * 0.075)
        ..lineTo(size.width * 0.90, horizonY - size.height * 0.066)
        ..lineTo(size.width, horizonY - size.height * 0.02)
        ..lineTo(size.width, horizonY)
        ..close(),
      ice,
    );
  }

  void _paintBergsBelow(Canvas canvas, Size size, double t) {
    // The nine tenths of it that is under the water: pale, enormous, and lit
    // from above so it reads as ice rather than as rock.
    final face = Path()
      ..moveTo(size.width * 0.58, size.height * surface)
      ..lineTo(size.width * 1.04, size.height * surface)
      ..lineTo(size.width * 0.99, size.height * 0.86)
      ..lineTo(size.width * 0.78, size.height * 0.72)
      ..lineTo(size.width * 0.66, size.height * 0.62)
      ..close();
    canvas.drawPath(
      face,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF7FC4E4).withValues(alpha: 0.34),
            const Color(0xFF19506B).withValues(alpha: 0.20),
          ],
        ).createShader(Rect.fromLTRB(size.width * 0.58,
            size.height * surface, size.width, size.height * 0.86)),
    );
    canvas.drawPath(
      face,
      Paint()
        ..color = const Color(0xFFCFEBFA).withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  // -- open water ------------------------------------------------------------

  void _paintBaitBall(Canvas canvas, Size size, double t) {
    // The only thing to look at in open water is other fish. A shoal, turning
    // as one, well off in the murk.
    final cx = size.width * 0.30 + math.sin(t * 0.32) * size.width * 0.12;
    final cy = size.height * 0.66 + math.cos(t * 0.27) * size.height * 0.05;
    final paint = Paint()..color = Colors.black.withValues(alpha: 0.28);
    for (var i = 0; i < 26; i++) {
      final a = i * 2.39996; // golden angle, so it never looks like a grid
      final r = 4.0 * math.sqrt(i) * 2.6;
      final x = cx + math.cos(a + t * 0.5) * r;
      final y = cy + math.sin(a + t * 0.5) * r * 0.55;
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, y), width: 7, height: 2.6),
        paint,
      );
    }
  }

  /// The underside of the ice, drawn hard against the top of the column.
  void paintCeiling(Canvas canvas, Size size, double t) {
    if (!iceCeiling) return;
    final y = size.height * surface;
    canvas.drawRect(
      Rect.fromLTRB(0, y - 2, size.width, y + 14),
      Paint()..color = const Color(0xFFBFE4F5).withValues(alpha: 0.30),
    );
    // Cracks running through it, lit from above.
    final crack = Paint()
      ..color = const Color(0xFFDFF4FF).withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (var i = 0; i < 5; i++) {
      final x = size.width * (0.08 + i * 0.21);
      canvas.drawPath(
        Path()
          ..moveTo(x, y + 14)
          ..lineTo(x + 9, y + 4)
          ..lineTo(x + 4, y - 2),
        crack,
      );
    }
  }
}
