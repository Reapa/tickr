import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/encounter_sim.dart' show Move;
import 'biome.dart';
import 'fish_shapes.dart';
import 'sea.dart';

/// The fight, drawn.
///
/// This file owns nothing about the rules — it is handed the state of the
/// simulation each frame and turns it into a place. What it is trying to sell,
/// in order of how much it matters:
///
///   * the rod. A loaded rod bends, and you can read the load off the curve
///     before you look at the gauge. It is the single most readable instrument
///     in real fishing and it was missing entirely.
///   * the line. Slack line bows and goes dull; loaded line goes straight,
///     bright and thin, and hums.
///   * the fish. A shape that beats its tail, banks, turns side-on when it runs
///     and rises through lighter water as you gain on it.
///   * the water reacting: chop that builds with the load, ripples where the
///     line cuts the surface, a wake behind a running fish, spray on a breach.
class FightScene extends CustomPainter {
  FightScene({
    required this.t,
    required this.biome,
    required this.palette,
    required this.tension,
    required this.progress,
    required this.surge,
    required this.strain,
    required this.fishScale,
    this.plan = BodyPlan.roundfish,
    this.action = Move.work,
    this.actionPhase = 0,
    required this.hooked,
    required this.reeling,
    required this.bobber,
    required this.bobberDip,
    required this.breach,
    required this.snapped,
    required this.fx,
    required this.shake,
  });

  /// Seconds since the cast landed.
  final double t;

  /// Which stretch of water this is. Owns the light, the visibility and every
  /// piece of scenery; the pipeline below is the same everywhere.
  final Biome biome;
  final SeaPalette palette;
  final double tension;
  final double progress;

  /// 0..1 — how hard the fish is running right now.
  final double surge;

  /// 0..1 — how far past the top of the tension band the line is.
  final double strain;

  /// Relative size of the fish, from the server's shadow class.
  final double fishScale;

  /// What kind of animal it is. The silhouette is the only thing you see of it
  /// before it is in the boat, so it is doing all the work of telling you what
  /// you have hooked.
  final BodyPlan plan;

  /// What the animal is doing right now, and how far through it — 0 at the
  /// start of the move, 1 at the end.
  ///
  /// The scene used to be told only "tension" and "surge", so a jump borrowed
  /// the landing leap and a sound was just a number going down. Every move now
  /// gets its own choreography AND its own camera, because what sells a fish
  /// going deep is not the fish moving down the frame — it is the frame going
  /// with it.
  final Move action;
  final double actionPhase;

  /// False during the wait, when there is a float on the water and nothing else.
  final bool hooked;
  final bool reeling;

  /// Whether to draw the float at all.
  final bool bobber;

  /// 0..1 — how far under the float has been pulled.
  final double bobberDip;

  /// 0..1 — the landing leap. Above zero the fish is out of the water.
  final double breach;
  final bool snapped;
  final FightFx fx;
  final Offset shake;

  // -- geometry ---------------------------------------------------------------
  //
  // The frame is a cutaway: sky down to [_horizon], the surface of the water
  // receding from [_surface] back to that horizon, and below [_surface] the
  // water column in section. Everything positional hangs off those two lines,
  // and the waterline is *drawn* — the first version computed one and never
  // painted it, which left the float and the spray hanging in open blue.

  double get _horizon => biome.horizon;
  double get _surface => biome.surface;

  SeaBand _nearBand(double chop) => SeaBand(
        rest: _surface,
        amp: 8.0 + chop * 7,
        len: 52,
        speed: 0.85,
        phase: 1.1,
        color: Colors.transparent,
      );

  double _surfaceY(double x, Size size, double chop) =>
      _nearBand(chop).yAt(x, t, size, chop: chop);

  /// The float, riding the swell out where the bait went in.
  Offset _floatAt(Size size, double chop) {
    final x = size.width * 0.62;
    return Offset(x, _surfaceY(x, size, chop));
  }

  /// Where the bait is hanging, under the float.
  Offset _baitAt(Size size, double chop) =>
      _floatAt(size, chop) + Offset(0, size.height * 0.17);

  /// Where the fish is, in pixels. Before the hook it circles the bait; after
  /// it, far and deep at first and close and high in the water as you win.
  Offset _fishAt(Size size, double chop) {
    if (!hooked && breach <= 0) {
      final bait = _baitAt(size, chop);
      return bait +
          Offset(math.cos(t * 0.62) * 84, math.sin(t * 0.62) * 24);
    }
    final near = progress;
    final sway =
        surge > 0 ? math.sin(t * 11) * 18 * surge : math.sin(t * 1.7) * 7;
    var x = size.width * (0.90 - 0.44 * near) + sway;
    var y = size.height * (0.80 - 0.28 * near) + math.sin(t * 2.1) * 7;

    // Each move drags it off its resting track, and EVERY move is scaled by a
    // rise-and-fall so it both begins and ends exactly where the fish would
    // otherwise have been.
    //
    // This is not decoration. Displacing by the raw phase left `sound` and
    // `bore` sitting at full offset on their final frame, so the instant the
    // move ended the fish teleported back across the frame. Anything that does
    // not return to zero under its own steam snaps.
    final k = actionPhase.clamp(0.0, 1.0);
    final swell = math.sin(k * math.pi);
    switch (action) {
      case Move.jump:
        // Ballistic: out of the water and back into it, blended by the same
        // swell so launch and splashdown both meet the resting track.
        y += (_jumpY(size, k) - y) * swell;
        x += swell * size.width * 0.06;
      case Move.sound:
        // Down hard, then levered back up — which is literally what answering
        // it with side pressure does.
        y += swell * size.height * 0.24;
        x -= swell * size.width * 0.03;
      case Move.run:
        // Tears away across the frame — the one move that is mostly sideways.
        x += swell * size.width * 0.30;
        y -= swell * size.height * 0.03;
      case Move.thrash:
        // Barely travels. All of it is violence in place.
        x += math.sin(t * 26) * 13 * swell;
        y += math.sin(t * 31) * 8 * swell;
      case Move.bore:
        // Toward the structure, which lives on the left of every biome that
        // has any.
        x -= swell * size.width * 0.18;
        y += swell * size.height * 0.07;
      case Move.work:
        break;
    }
    return Offset(x, y);
  }

  /// Where the camera is, relative to its resting position. A sounding fish
  /// pulls the frame down after it; a jump lifts it; a run drifts with it.
  Offset _camera(Size size) {
    final k = actionPhase.clamp(0.0, 1.0);
    final swell = math.sin(k * math.pi);
    return switch (action) {
      Move.sound => Offset(0, -k * size.height * 0.10),
      Move.jump => Offset(0, swell * size.height * 0.05),
      Move.run => Offset(-swell * size.width * 0.05, 0),
      Move.bore => Offset(swell * size.width * 0.03, 0),
      _ => Offset.zero,
    };
  }

  /// The jump's trajectory. Sits below the waterline at both ends.
  double _jumpY(Size size, double k) {
    final launch = size.height * (_surface + 0.14);
    final rise = 4 * k * (1 - k); // parabola, 0 -> 1 -> 0
    return launch - rise * size.height * 0.34;
  }

  /// Whether the fish is genuinely clear of the water, rather than merely in
  /// the middle of a jump. Drawing it unclipped for the whole move let it swim
  /// through the surface bands on the way up.
  bool _isAirborne(Size size) {
    if (action != Move.jump) return false;
    return _jumpY(size, actionPhase.clamp(0.0, 1.0)) <
        size.height * _surface - 6;
  }

  /// How wet it still looks, 0..1 — full at the moment it clears.
  double get _airborne =>
      action == Move.jump ? math.sin(actionPhase.clamp(0.0, 1.0) * math.pi) : 0;

  Offset _rodButt(Size size) => Offset(size.width * 0.07, size.height * 1.02);

  /// The tip, pulled down and out toward the fish as the line loads. This is
  /// the bend; everything else about the rod follows from it.
  Offset _rodTip(Size size) {
    final load = tension.clamp(0.0, 1.1);
    // A rod under load also judders — the fish's head shakes travel up the
    // blank, and that judder is the first thing you feel in real life.
    final judder = math.sin(t * 13) * 2.2 * strain + math.sin(t * 21) * 3 * surge;
    return Offset(
      size.width * (0.40 + 0.13 * load),
      size.height * (0.09 + 0.27 * load) + judder,
    );
  }

  Offset _rodCtrl(Size size) {
    final butt = _rodButt(size);
    final tip = _rodTip(size);
    // The control point sits above the chord when the rod is straight and gets
    // dragged toward the chord as it loads, so the blank bends through its top
    // third the way a real one does.
    final mid = Offset((butt.dx + tip.dx) / 2, (butt.dy + tip.dy) / 2);
    return mid + Offset(-size.width * 0.055 * (1 - tension * 0.35), -18);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // A canvas can be handed to us with no area at all mid-layout, and several
    // things here divide or take a modulus by a dimension. There is nothing to
    // draw at that point anyway.
    if (size.width < 1 || size.height < 1) return;

    final chop = (strain * 0.7 + surge * 0.5).clamp(0.0, 1.0);
    final p = palette;

    canvas.save();
    final cam = _camera(size);
    canvas.translate(shake.dx + cam.dx, shake.dy + cam.dy);

    // The shot tightens as the fish comes in. A fight that is framed identically
    // at 40 metres and at the gunwale has no arc to it — the animal simply
    // slides up the same picture. Pushing in as you win ground is what makes the
    // end of a fight feel like the end of one. A live hazard punches in further,
    // then releases.
    final zoom = 1 +
        0.20 * progress +
        0.06 * math.sin(actionPhase.clamp(0.0, 1.0) * math.pi) *
            (action == Move.work ? 0 : 1);
    if (zoom > 1.001) {
      // Anchored below centre, toward where the fish and the rod tip both live,
      // so pushing in does not crop the rod out of frame.
      final focus = Offset(size.width * 0.46, size.height * 0.56);
      canvas
        ..translate(focus.dx, focus.dy)
        ..scale(zoom)
        ..translate(-focus.dx, -focus.dy);
    }

    final horizonY = size.height * _horizon;
    final surfaceRest = size.height * _surface;

    paintSky(canvas, size, p,
        horizonY: horizonY,
        t: t,
        sunX: biome.sunX,
        stars: biome.stars * (1 - strain));
    biome.paintSkyline(canvas, size, t);

    // The surface of the sea, in perspective: horizon at the back, the near
    // waterline at the front, with the swell getting bigger as it comes on.
    final plane = Rect.fromLTRB(0, horizonY, size.width, surfaceRest + 2);
    canvas.drawRect(
      plane,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(p.skyHorizon, p.surface, 0.45)!, p.surface],
        ).createShader(plane),
    );
    _paintGlitter(canvas, size, p, horizonY, surfaceRest, chop);
    for (var i = 0; i < 3; i++) {
      SeaBand(
        rest: _horizon + (_surface - _horizon) * (0.30 + i * 0.26),
        amp: (1.4 + i * 1.6) * (1 + chop),
        len: 26.0 + i * 16,
        speed: 0.5 + i * 0.2,
        phase: i * 2.1,
        // No foam back here: broken white on a band this small reads as a
        // dashed line ruled across the sea rather than as a wave.
        color: Color.lerp(p.surface, p.deep, 0.16 + i * 0.07)!,
      ).paint(canvas, size, t, chop: chop);
    }

    final fish = _fishAt(size, chop);
    final float = _floatAt(size, chop);
    final tip = _rodTip(size);
    final ctrl = _rodCtrl(size);

    // Before the hook the rig ends at the float; after it, the line goes to the
    // fish's head rather than its middle, because that is where the hook is.
    final headOffset = (46 + 108 * fishScale) * (0.72 + 0.42 * progress) * 0.34;
    final target = hooked || breach > 0
        ? fish.translate(-headOffset, 0)
        : float;
    final linePts = _linePoints(size, tip, target);
    final entryIndex = _entryIndex(linePts, size, chop);
    final entry = linePts[entryIndex.clamp(0, linePts.length - 1)];
    fx
      ..entry = hooked ? entry : float
      ..fishAt = fish
      ..surfaceY = _surfaceY(entry.dx, size, chop);

    // The water column, clipped to the actual shape of the surface so its top
    // edge is the swell rather than a straight cut.
    final column = Path()..moveTo(-4, _surfaceY(-4, size, chop));
    for (double x = -4; x <= size.width + 8; x += 6) {
      column.lineTo(x, _surfaceY(x, size, chop));
    }
    column
      ..lineTo(size.width + 8, size.height + 8)
      ..lineTo(-4, size.height + 8)
      ..close();

    canvas.save();
    canvas.clipPath(column);
    final col = Rect.fromLTRB(0, surfaceRest, size.width, size.height);
    canvas.drawRect(
      col,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(p.surface, p.deep, 0.25)!, p.deep],
          stops: const [0.0, 0.9],
        ).createShader(col),
    );
    // Scenery behind the fish, then the light, then the fish, then whatever
    // this place has in the foreground for it to swim behind.
    biome.paintFar(canvas, size, t, chop);
    _paintShafts(
        canvas, size, p, surfaceRest, biome.shafts * (1 - strain * 0.6));
    _paintMotes(canvas, size, p, surfaceRest);
    biome.paintCeiling(canvas, size, t);
    _paintSubsurfaceLine(canvas, linePts, entryIndex);
    if (!hooked) _paintLeader(canvas, size, float, chop, p);
    _paintBubbles(canvas, p);
    // A jumping fish is above the waterline, so it must NOT be drawn inside the
    // clip that keeps everything else under it.
    if (breach < 0.5 && !_isAirborne(size)) _paintFish(canvas, size, fish, p);
    biome.paintNear(canvas, size, t, chop);
    canvas.restore();

    // The waterline itself. This is the line everything else is measured
    // against, so it gets a bright lip and broken foam along it.
    _paintWaterline(canvas, size, p, chop);

    _paintWake(canvas, size, fish, chop, p);
    _paintEntry(canvas, entry, p);
    _paintAerialLine(canvas, linePts, entryIndex);

    if (bobber) _paintBobber(canvas, size, float, p);
    if (breach >= 0.5) _paintBreach(canvas, size, entry, p);
    // Out of the water, over the surface bands, with the light on its flank.
    if (_isAirborne(size) && breach < 0.5) _paintAirborne(canvas, size, fish, p);

    _paintDrops(canvas, p);
    _paintRodAndBoat(canvas, size, tip, ctrl, p);

    canvas.restore();

    paintVignette(canvas, size, strength: 0.5 + strain * 0.22);
    if (strain > 0) {
      // A warm bloom around the edge as the line goes past what it will hold.
      final rect = Offset.zero & size;
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            radius: 0.9,
            colors: [
              Colors.transparent,
              const Color(0xFFFF5A52)
                  .withValues(alpha: 0.30 * strain * (0.7 + 0.3 * math.sin(t * 9))),
            ],
            stops: const [0.45, 1.0],
          ).createShader(rect),
      );
    }
  }

  // -- pieces -----------------------------------------------------------------

  /// The sun's path broken up across the far water. Cheap, and it does more to
  /// make the surface read as a surface than anything else in the frame.
  void _paintGlitter(Canvas canvas, Size size, SeaPalette p, double horizonY,
      double surfaceRest, double chop) {
    final sx = size.width * biome.sunX;
    final paint = Paint();
    for (var i = 0; i < 26; i++) {
      final k = i / 25;
      final y = horizonY + (surfaceRest - horizonY) * k;
      // The path fans out as it comes toward you, and the flecks get longer.
      final spread = 6 + 74 * k * k;
      final phase = math.sin(t * 2.1 + i * 2.7);
      final x = sx + phase * spread + (i.isEven ? -1 : 1) * spread * 0.35;
      paint.color = p.glow.withValues(
          alpha: (0.30 - 0.14 * k) *
              (0.45 + 0.55 * phase.abs()) *
              biome.glitter);
      canvas.drawOval(
        Rect.fromCenter(
            center: Offset(x, y), width: 5 + 16 * k, height: 1.1 + 1.4 * k),
        paint,
      );
    }
  }

  /// Light coming down through the column. Redrawn here rather than reusing the
  /// shared helper so the shafts start at the near waterline, not the horizon.
  void _paintShafts(Canvas canvas, Size size, SeaPalette p, double surfaceRest,
      double strength) {
    if (strength <= 0) return;
    final sx = size.width * biome.sunX;
    final rect = Rect.fromLTRB(0, surfaceRest, size.width, size.height);
    for (var i = 0; i < 5; i++) {
      final sway = math.sin(t * 0.28 + i * 1.9) * 24;
      final top = sx + (i - 2) * 30 + sway * 0.3;
      final spread = 24.0 + i * 10;
      final bottom = sx + (i - 2) * 140 + sway;
      canvas.drawPath(
        Path()
          ..moveTo(top - 6, surfaceRest)
          ..lineTo(top + 6, surfaceRest)
          ..lineTo(bottom + spread, size.height)
          ..lineTo(bottom - spread, size.height)
          ..close(),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              p.glow.withValues(alpha: 0.075 * strength),
              p.glow.withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
    }
  }

  /// Suspended particulate drifting through the beam. Nothing sells "this is a
  /// volume of water and not a blue rectangle" as cheaply as this does.
  void _paintMotes(Canvas canvas, Size size, SeaPalette p, double surfaceRest) {
    if (biome.motes <= 0) return;
    final paint = Paint()
      ..color = p.foam.withValues(alpha: 0.16 * biome.motes.clamp(0.0, 1.6));
    // The Trench is thick with marine snow; the Harbour has almost none.
    final count = (36 * biome.motes).round().clamp(0, _motes.length);
    for (var i = 0; i < count; i++) {
      final m = _motes[i];
      final drift = (m.dy - t * 0.008 * (0.4 + m.dx)) % 1.0;
      final y = surfaceRest + (size.height - surfaceRest) * drift;
      final x = (m.dx * size.width + math.sin(t * 0.4 + i) * 9) % size.width;
      canvas.drawCircle(Offset(x, y), i.isEven ? 0.9 : 1.4, paint);
    }
  }

  /// The bright lip where air meets water, and the foam broken along it.
  void _paintWaterline(Canvas canvas, Size size, SeaPalette p, double chop) {
    final crest = Path()..moveTo(-4, _surfaceY(-4, size, chop));
    for (double x = -4; x <= size.width + 8; x += 6) {
      crest.lineTo(x, _surfaceY(x, size, chop));
    }
    canvas.drawPath(
      crest,
      Paint()
        ..color = p.foam.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    final foam = Paint()..color = p.foam.withValues(alpha: 0.30 + 0.35 * chop);
    for (double x = 0; x <= size.width; x += 11) {
      final y = _surfaceY(x, size, chop);
      final rise = y - size.height * _surface;
      if (rise > -(2.5 + chop * 4)) continue;
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, y), width: 10, height: 2.2),
        foam,
      );
    }
  }

  /// The bit of line hanging under the float, down to the bait.
  void _paintLeader(
      Canvas canvas, Size size, Offset float, double chop, SeaPalette p) {
    final bait = _baitAt(size, chop);
    canvas.drawLine(
      float,
      bait,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.16)
        ..strokeWidth = 0.9,
    );
    canvas.drawCircle(
        bait, 2.6, Paint()..color = p.foam.withValues(alpha: 0.35));
  }

  List<Offset> _linePoints(Size size, Offset tip, Offset fish) {
    // Slack line bows under its own weight; a loaded one pulls to a chord. The
    // hum on a straining line is a small perpendicular ripple, not a wobble of
    // the whole curve.
    final slack = snapped ? 90.0 : (1 - tension.clamp(0.0, 1.0)) * 58 + 6;
    final ctrl = Offset(
      (tip.dx + fish.dx) / 2,
      (tip.dy + fish.dy) / 2 + slack,
    );
    final hum = strain * 3.2;
    return List<Offset>.generate(26, (i) {
      final s = i / 25;
      final inv = 1 - s;
      final base = Offset(
        inv * inv * tip.dx + 2 * inv * s * ctrl.dx + s * s * fish.dx,
        inv * inv * tip.dy + 2 * inv * s * ctrl.dy + s * s * fish.dy,
      );
      if (hum <= 0) return base;
      final wobble = math.sin(s * 9 + t * 30) * hum * math.sin(s * math.pi);
      return base + Offset(0, wobble);
    });
  }

  int _entryIndex(List<Offset> pts, Size size, double chop) {
    for (var i = 0; i < pts.length; i++) {
      if (pts[i].dy >= _surfaceY(pts[i].dx, size, chop)) return i;
    }
    return pts.length - 1;
  }

  void _paintAerialLine(Canvas canvas, List<Offset> pts, int entryIndex) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i <= entryIndex && i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    if (strain > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFFFF8A6B).withValues(alpha: 0.35 * strain)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.5,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
            .withValues(alpha: snapped ? 0.3 : 0.42 + 0.48 * tension)
        ..style = PaintingStyle.stroke
        ..strokeWidth = snapped ? 0.9 : 1.0 + 0.9 * tension,
    );
  }

  void _paintSubsurfaceLine(Canvas canvas, List<Offset> pts, int entryIndex) {
    if (entryIndex >= pts.length - 1) return;
    final path = Path()..moveTo(pts[entryIndex].dx, pts[entryIndex].dy);
    for (var i = entryIndex + 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.14 + 0.16 * tension)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  void _paintFish(Canvas canvas, Size size, Offset at, SeaPalette p) {
    final depth = (1 - progress).clamp(0.0, 1.0);
    final length = (46 + 108 * fishScale) * (0.72 + 0.42 * progress);

    // A fish deep in dirty water is a smudge; the detail arrives with it. How
    // much ever arrives is the biome's call — in the Trench you are still
    // guessing when it is alongside, which is the whole character of the place.
    final clarity =
        ((0.30 + 0.70 * progress) * biome.clarity).clamp(0.0, 1.0);

    canvas.save();
    canvas.translate(at.dx, at.dy);

    // The bulk of it, before the shape: a soft dark mass that survives depth.
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(0, 2), width: length * 1.15, height: length * 0.42),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30 + 0.22 * depth)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );

    // Turning side-on as it runs — a real fish shows you its flank and then
    // nothing at all when it swings away, so scale through zero rather than
    // spinning the sprite.
    final turn = surge;
    final flip = -math.cos(math.pi * turn);
    canvas.scale(
      flip.abs() < 0.14 ? (flip.isNegative ? -0.14 : 0.14) : flip,
      1.0,
    );
    canvas.rotate(math.sin(t * 1.3) * 0.06 - 0.12 * progress * (flip.sign));

    final beatHz = 4.5 + surge * 11 + (reeling ? 2.5 : 0);
    final shape = fishBody(plan, length,
        beat: math.sin(t * beatHz), bank: math.sin(t * 0.9) * 0.25);
    final path = shape.body;

    final body = Color.lerp(
        Colors.black, Color.lerp(p.surface, p.foam, 0.35)!, clarity * 0.55)!;
    final skin = Paint()
      ..color = body.withValues(alpha: 0.55 + 0.40 * clarity);
    // Fins first, darker AND translucent — they are membrane stretched over
    // rays, so light comes through them. Drawn opaque they read as bits of card
    // glued to the side of the animal.
    final finPaint = Paint()
      ..color = Color.lerp(body, Colors.black, 0.25)!
          .withValues(alpha: (0.34 + 0.30 * clarity));
    for (final fin in shape.fins) {
      canvas.drawPath(fin, finPaint);
      // A brighter leading edge, which is where a fin actually catches light.
      canvas.drawPath(
        fin,
        Paint()
          ..color = p.foam.withValues(alpha: 0.14 * clarity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9,
      );
    }
    canvas.drawPath(path, skin);

    // Where there is no sun, the animal lights itself. A row of photophores
    // along the flank is the only reason you can track it at all down there.
    if (biome.bioluminescence > 0) {
      final glow = Paint()
        ..color = p.glow.withValues(
            alpha: 0.55 * biome.bioluminescence *
                (0.55 + 0.45 * math.sin(t * 2.6)));
      for (var i = 0; i < 7; i++) {
        final x = length * (0.30 - i * 0.09);
        canvas.drawCircle(Offset(x, length * 0.055), 1.5, glow);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = p.glow.withValues(alpha: 0.30 * biome.bioluminescence)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1,
      );
    }

    // Shading. A fish is not a flat colour: it is dark along the back, pale
    // underneath, glossy where the light hits it, and covered in scales. Doing
    // none of that was what made every one of these read as a paper cut-out no
    // matter how good the outline was.
    if (clarity > 0.25) {
      canvas.save();
      canvas.clipPath(path);
      final r = Rect.fromCenter(
          center: Offset.zero, width: length * 1.2, height: length * 0.8);

      // 1. Countershading — genuinely how fish are coloured, and the single
      //    biggest step away from a flat fill.
      canvas.drawRect(
        r,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.42 * clarity),
              Colors.transparent,
              p.foam.withValues(alpha: 0.40 * clarity),
            ],
            stops: const [0.0, 0.48, 1.0],
          ).createShader(r),
      );

      // 2. Scales: two crossed families of fine arcs. Cheap, and at a glance it
      //    reads as texture rather than as pattern.
      if (clarity > 0.55) {
        final scale = Paint()
          ..color = Colors.white.withValues(alpha: 0.05 * clarity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8;
        final step = length * 0.055;
        for (var i = -6; i < 10; i++) {
          final x = i * step;
          canvas.drawArc(
            Rect.fromCenter(
                center: Offset(x, 0), width: step * 2.4, height: length * 0.62),
            -math.pi * 0.62,
            math.pi * 1.24,
            false,
            scale,
          );
        }
      }

      // 3. Caustics — the surface's own ripples drifting across its flank. This
      //    is what ties the animal to the water it is in rather than leaving it
      //    looking pasted on top.
      // Clamped: the Reef's hard sunlight multiplier is 1.5, which turned these
      // from a shimmer into white slashes painted down the flank.
      final caustic = Paint()
        ..color = p.foam.withValues(
            alpha: 0.075 * clarity * biome.shafts.clamp(0.0, 1.0));
      for (var i = 0; i < 4; i++) {
        final x = ((t * 26 + i * length * 0.34) % (length * 1.5)) - length * 0.7;
        canvas.drawOval(
          Rect.fromCenter(
              center: Offset(x, -length * 0.10),
              width: length * 0.09,
              height: length * 0.42),
          caustic,
        );
      }

      // 4. The wet highlight running along the top of the back.
      canvas.drawOval(
        Rect.fromCenter(
            center: Offset(length * 0.02, -length * 0.20),
            width: length * 0.62,
            height: length * 0.10),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.16 * clarity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      canvas.restore();

      // Eye, with a catchlight — the one detail that makes it look alive.
      final eye = Offset(length * 0.34, -length * 0.045);
      canvas.drawCircle(eye, length * 0.030,
          Paint()..color = Colors.black.withValues(alpha: 0.85 * clarity));
      canvas.drawCircle(
        eye.translate(-length * 0.008, -length * 0.010),
        length * 0.010,
        Paint()..color = Colors.white.withValues(alpha: 0.55 * clarity),
      );
    }

    canvas.restore();
  }

  /// The V a running fish pushes ahead of itself, and the disturbed water it
  /// leaves behind.
  void _paintWake(
      Canvas canvas, Size size, Offset fish, double chop, SeaPalette p) {
    if (surge <= 0.05 || progress < 0.12) return;
    final y = _surfaceY(fish.dx, size, chop);
    final paint = Paint()
      ..color = p.foam.withValues(alpha: 0.16 * surge)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    for (var i = 1; i <= 3; i++) {
      final spread = i * 22.0;
      canvas.drawPath(
        Path()
          ..moveTo(fish.dx - spread * 1.6, y - spread * 0.30)
          ..lineTo(fish.dx, y)
          ..lineTo(fish.dx + spread * 1.6, y - spread * 0.30),
        paint,
      );
    }
  }

  /// Where the line cuts the water: a bright pinch and the rings running off it.
  void _paintEntry(Canvas canvas, Offset at, SeaPalette p) {
    for (final ring in fx.rings) {
      canvas.drawOval(
        Rect.fromCenter(
            center: ring.at, width: ring.r * 2.4, height: ring.r * 0.72),
        Paint()
          ..color = p.foam.withValues(alpha: 0.42 * ring.life)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3,
      );
    }
    if (!hooked) return;
    canvas.drawOval(
      Rect.fromCenter(center: at, width: 16 + 14 * tension, height: 5),
      Paint()..color = p.foam.withValues(alpha: 0.30 + 0.35 * tension),
    );
  }

  /// The float, before anything has taken it. It rides the swell, nods on a
  /// nibble, and goes under when the fish commits.
  void _paintBobber(Canvas canvas, Size size, Offset at, SeaPalette p) {
    final sink = bobberDip * 22;
    final c = Offset(at.dx, at.dy + sink);
    final tilt = math.sin(t * 2.4) * 0.18 + bobberDip * 0.5;

    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(tilt);
    // Waterline ellipse first, so the float sits in the surface not on it.
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 22, height: 6),
      Paint()..color = p.deep.withValues(alpha: 0.5),
    );
    final visible = (1 - bobberDip).clamp(0.0, 1.0);
    if (visible > 0.02) {
      canvas.drawPath(
        Path()
          ..moveTo(-5, 1)
          ..lineTo(5, 1)
          ..lineTo(3, -11 * visible)
          ..lineTo(-3, -11 * visible)
          ..close(),
        Paint()..color = const Color(0xFFFF5A52).withValues(alpha: 0.95),
      );
      canvas.drawRect(
        Rect.fromLTWH(-3.4, -13 * visible, 6.8, 3.5 * visible),
        Paint()..color = Colors.white.withValues(alpha: 0.9),
      );
    }
    canvas.restore();
  }

  /// A fish in mid-air during a jump.
  ///
  /// The angle comes from the arc it is actually on rather than being animated
  /// separately — nose up on the way out, over at the top, nose down on the way
  /// in. Getting that wrong is what makes a jump read as a sticker being slid
  /// up the screen.
  void _paintAirborne(Canvas canvas, Size size, Offset at, SeaPalette p) {
    final k = actionPhase.clamp(0.0, 1.0);
    final length = (46 + 108 * fishScale) * (0.80 + 0.35 * progress);
    // d(height)/dk of the 4k(1-k) arc, so the pitch follows the trajectory.
    final climb = 4 - 8 * k;
    final pitch = -math.atan(climb * 0.55);

    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.scale(-1, 1); // facing the boat
    canvas.rotate(-pitch);

    final shape = fishBody(plan, length, beat: math.sin(t * 26) * 1.1);
    final wet = Color.lerp(p.deep, p.surface, 0.55)!;
    for (final fin in shape.fins) {
      canvas.drawPath(fin, Paint()..color = Color.lerp(wet, Colors.black, 0.2)!);
    }
    canvas.drawPath(shape.body, Paint()..color = wet);
    // Wet flank catching the sky — the reason a jump reads at all.
    canvas.save();
    canvas.clipPath(shape.body);
    final r =
        Rect.fromCenter(center: Offset.zero, width: length, height: length * 0.7);
    canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.55),
            Colors.transparent,
            p.foam.withValues(alpha: 0.55),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(r),
    );
    canvas.restore();
    canvas.restore();

    // Water coming off it, thrown along the direction of travel.
    final trail = Paint()..color = p.foam.withValues(alpha: 0.5 * _airborne);
    for (var i = 0; i < 7; i++) {
      final s = i / 6;
      canvas.drawCircle(
        at.translate(length * 0.30 * s, length * 0.10 * s + climb * -3 * s),
        2.4 * (1 - s),
        trail,
      );
    }
  }

  /// The landing leap. The one moment the fish is fully out of the water, so it
  /// gets the whole budget: rotation, spray, and light on its flank.
  void _paintBreach(Canvas canvas, Size size, Offset entry, SeaPalette p) {
    final k = ((breach - 0.5) / 0.5).clamp(0.0, 1.0);
    final arc = math.sin(k * math.pi);
    final length = (46 + 108 * fishScale) * 1.15;
    final at = Offset(
      entry.dx + 30 * k,
      entry.dy - arc * 92,
    );
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.scale(-1, 1);
    canvas.rotate(-0.85 + k * 1.5);
    final shape = fishBody(plan, length, beat: math.sin(t * 22) * 1.2);
    final path = shape.body;
    final skin = Paint()..color = Color.lerp(p.deep, p.surface, 0.5)!;
    for (final fin in shape.fins) {
      canvas.drawPath(fin, skin);
    }
    canvas.drawPath(path, skin);
    canvas.save();
    canvas.clipPath(path);
    final r =
        Rect.fromCenter(center: Offset.zero, width: length, height: length * 0.7);
    canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.55),
            Colors.transparent,
            p.foam.withValues(alpha: 0.8),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(r),
    );
    canvas.restore();
    canvas.restore();
  }

  void _paintBubbles(Canvas canvas, SeaPalette p) {
    for (final b in fx.bubbles) {
      canvas.drawCircle(
        Offset(b.x, b.y),
        b.r,
        Paint()
          ..color = p.foam.withValues(alpha: 0.26 * b.life)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  void _paintDrops(Canvas canvas, SeaPalette p) {
    for (final d in fx.drops) {
      final a = d.life.clamp(0.0, 1.0);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(d.x, d.y),
          width: d.r * 1.1,
          height: d.r * (1 + d.vy.abs() * 0.02),
        ),
        Paint()..color = p.foam.withValues(alpha: 0.75 * a),
      );
    }
  }

  /// The foreground: the gunwale you are standing behind, the rod, and the
  /// reel turning while you wind.
  void _paintRodAndBoat(
      Canvas canvas, Size size, Offset tip, Offset ctrl, SeaPalette p) {
    final butt = _rodButt(size);
    final hull = Color.lerp(p.deep, Colors.black, 0.55)!;

    // Gunwale: a dark sweep across the bottom of the frame with a rail on it.
    final deck = Path()
      ..moveTo(-4, size.height + 4)
      ..lineTo(-4, size.height * 0.90)
      ..quadraticBezierTo(size.width * 0.36, size.height * 0.80,
          size.width + 4, size.height * 0.955)
      ..lineTo(size.width + 4, size.height + 4)
      ..close();
    canvas.drawPath(deck, Paint()..color = hull);
    canvas.drawPath(
      Path()
        ..moveTo(-4, size.height * 0.90)
        ..quadraticBezierTo(size.width * 0.36, size.height * 0.80,
            size.width + 4, size.height * 0.955),
      Paint()
        ..color = p.foam.withValues(alpha: 0.12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );

    // The blank, tapered from butt to tip along the bend.
    const steps = 22;
    final left = <Offset>[];
    final right = <Offset>[];
    for (var i = 0; i <= steps; i++) {
      final s = i / steps;
      final inv = 1 - s;
      final pt = Offset(
        inv * inv * butt.dx + 2 * inv * s * ctrl.dx + s * s * tip.dx,
        inv * inv * butt.dy + 2 * inv * s * ctrl.dy + s * s * tip.dy,
      );
      final d = Offset(
        2 * inv * (ctrl.dx - butt.dx) + 2 * s * (tip.dx - ctrl.dx),
        2 * inv * (ctrl.dy - butt.dy) + 2 * s * (tip.dy - ctrl.dy),
      );
      final len = math.max(0.001, d.distance);
      final n = Offset(-d.dy / len, d.dx / len);
      final half = (5.2 * (1 - s) + 0.75) * 0.9;
      left.add(pt + n * half);
      right.add(pt - n * half);
    }
    final blank = Path()..moveTo(left.first.dx, left.first.dy);
    for (final o in left.skip(1)) {
      blank.lineTo(o.dx, o.dy);
    }
    for (final o in right.reversed) {
      blank.lineTo(o.dx, o.dy);
    }
    blank.close();
    canvas.drawPath(blank, Paint()..color = const Color(0xFF161A20));
    canvas.drawPath(
      blank,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );

    // Guides, and a bright tip ring so the eye tracks the bend.
    final guide = Paint()
      ..color = Colors.white.withValues(alpha: 0.30)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final s in const [0.42, 0.62, 0.80, 0.94]) {
      final i = (s * steps).round();
      final centre = Offset(
        (left[i].dx + right[i].dx) / 2,
        (left[i].dy + right[i].dy) / 2,
      );
      canvas.drawCircle(centre, 3.4 - s * 1.6, guide);
    }
    canvas.drawCircle(
      tip,
      2.6,
      Paint()..color = Colors.white.withValues(alpha: 0.5 + 0.4 * tension),
    );

    // Reel. Spins while you wind, and screams when the fish takes line.
    final reelAt = Offset(
      butt.dx + (ctrl.dx - butt.dx) * 0.30,
      butt.dy + (ctrl.dy - butt.dy) * 0.30,
    );
    final spin = fx.reelAngle;
    canvas.save();
    canvas.translate(reelAt.dx, reelAt.dy);
    canvas.drawCircle(Offset.zero, 15, Paint()..color = const Color(0xFF10141A));
    canvas.drawCircle(
      Offset.zero,
      15,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3,
    );
    canvas.rotate(spin);
    final spoke = Paint()
      ..color = Colors.white.withValues(alpha: reeling ? 0.4 : 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (var i = 0; i < 3; i++) {
      final a = i * math.pi * 2 / 3;
      canvas.drawLine(
          Offset.zero, Offset(math.cos(a) * 11, math.sin(a) * 11), spoke);
    }
    canvas.restore();
    canvas.drawCircle(
        reelAt, 4, Paint()..color = Colors.white.withValues(alpha: 0.28));
  }

  @override
  bool shouldRepaint(FightScene old) => true;
}

/// Fixed particulate, in fractional coordinates. Seeded so it drifts instead of
/// reshuffling itself every frame.
final List<Offset> _motes = () {
  final rng = math.Random(90210);
  return List<Offset>.generate(
      90, (_) => Offset(rng.nextDouble(), rng.nextDouble()));
}();

// ---------------------------------------------------------------------------
// Particles
// ---------------------------------------------------------------------------

/// A droplet of spray, under gravity.
class Drop {
  Drop(this.x, this.y, this.vx, this.vy, this.r);
  double x, y, vx, vy, r;
  double life = 1;
}

/// Air coming off a working fish, on its way up.
class Bubble {
  Bubble(this.x, this.y, this.r, this.speed);
  double x, y, r, speed;
  double life = 1;
}

/// A ripple running out from where something broke the surface.
class Ring {
  Ring(this.at);
  final Offset at;
  double r = 3;
  double life = 1;
}

/// Everything in the scene that has its own momentum: spray, bubbles, the rings
/// running off the line, and the reel's rotation.
///
/// Kept out of the painter because a painter is rebuilt every frame and these
/// have to survive between them.
class FightFx {
  final List<Drop> drops = [];
  final List<Bubble> bubbles = [];
  final List<Ring> rings = [];

  /// Written by the painter each frame, read by the panel when it wants to
  /// spawn something at a place that only the scene's geometry knows: where the
  /// line cuts the water, and where the fish currently is. Cheaper and far less
  /// error-prone than duplicating the layout maths in two files.
  Offset entry = Offset.zero;
  Offset fishAt = Offset.zero;
  double surfaceY = 0;

  double reelAngle = 0;
  double _bubbleTimer = 0;
  double _ringTimer = 0;

  final math.Random _rng = math.Random();

  /// Advance every particle. [surfaceY] is where bubbles pop and where a
  /// falling droplet stops existing.
  void step(double dtMs, {required double surfaceY, required double reelRate}) {
    final dt = dtMs / 1000.0;
    reelAngle += reelRate * dt;

    for (final d in drops) {
      d.vy += 1500 * dt; // gravity, in the same pixel space as everything else
      d.x += d.vx * dt;
      d.y += d.vy * dt;
      d.life -= dt * 1.1;
    }
    drops.removeWhere((d) => d.life <= 0 || (d.vy > 0 && d.y > surfaceY + 40));

    for (final b in bubbles) {
      b.y -= b.speed * dt;
      b.x += math.sin(b.y * 0.06) * 12 * dt;
      b.life -= dt * 0.35;
    }
    bubbles.removeWhere((b) => b.life <= 0 || b.y < surfaceY);

    for (final r in rings) {
      r.r += 46 * dt;
      r.life -= dt * 1.3;
    }
    rings.removeWhere((r) => r.life <= 0);

    _bubbleTimer -= dtMs;
    _ringTimer -= dtMs;
  }

  /// Spray. [power] scales both how many droplets and how hard they go up.
  void splash(Offset at, {double power = 1}) {
    final n = (8 + 22 * power).round();
    for (var i = 0; i < n; i++) {
      final a = -math.pi / 2 + (_rng.nextDouble() - 0.5) * 2.2;
      final v = (110 + _rng.nextDouble() * 240) * power;
      drops.add(Drop(
        at.dx + (_rng.nextDouble() - 0.5) * 22,
        at.dy,
        math.cos(a) * v,
        math.sin(a) * v,
        1.4 + _rng.nextDouble() * 2.6,
      ));
    }
    ring(at);
  }

  void ring(Offset at) {
    if (rings.length > 8) return;
    rings.add(Ring(at));
  }

  /// Rings running off the line where it cuts the water. Rate-limited so a
  /// long fight does not end up drawing forty of them.
  void trickleRing(Offset at) {
    if (_ringTimer > 0) return;
    _ringTimer = 420;
    ring(at);
  }

  /// A struggling fish gasses off. More of it the harder it is working.
  void trickleBubbles(Offset from, double intensity) {
    if (_bubbleTimer > 0 || bubbles.length > 26) return;
    _bubbleTimer = 130 - 80 * intensity;
    bubbles.add(Bubble(
      from.dx + (_rng.nextDouble() - 0.5) * 26,
      from.dy,
      1.5 + _rng.nextDouble() * 2.5,
      34 + _rng.nextDouble() * 40,
    ));
  }

  void clear() {
    drops.clear();
    bubbles.clear();
    rings.clear();
  }
}
