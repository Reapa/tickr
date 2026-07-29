/// Body plans.
///
/// Every fish in the game was the same ellipse-with-a-tail at different sizes,
/// which meant a coelacanth, a squid and a great white were the same animal
/// wearing different numbers. A silhouette is the only thing you see of a fish
/// before it is in the boat, so it is doing all of the work of telling you what
/// you have hooked — and it was telling you nothing.
///
/// These are built as paths rather than drawn as assets for the same reason the
/// old one was: the tail has to beat, the body has to bank, and a fish that
/// slides across the screen without moving reads as a sticker. Each plan takes
/// the same [beat] and [bank] so the scene does not care which one it has.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// How a species is built. Chosen from the species code where the client knows
/// it, and otherwise inferred from how the thing fights — which is genuinely
/// all you have mid-encounter, and is the point of the shadow.
enum BodyPlan {
  /// Long, forked tail, deep flank. Herring, mackerel, salmon.
  torpedo,

  /// Crescent tail, hard shoulders, finlets down the back. Tuna, swordfish.
  tuna,

  /// A bill and a great standing sail. Marlin, swordfish, sailfish.
  billfish,

  /// Asymmetric tail, tall first dorsal, pointed snout. Sharks.
  shark,

  /// Wide, flat, both eyes up one side. Halibut, rays, flatfish.
  flat,

  /// Mantle, fins at the top, a fistful of arms. Squid.
  cephalopod,

  /// Heavy, lobed, primitive. Coelacanth — deliberately strange.
  lobefin,

  /// Deep-bodied and round. Cod, bass, snapper, koi, sardine.
  roundfish;

  /// The plan for a species code. Falls back on the round body, which is what
  /// most fish in the catalog actually are.
  static BodyPlan of(String? species) => switch (species) {
        'herring' || 'mackerel' || 'salmon' => BodyPlan.torpedo,
        'tuna' => BodyPlan.tuna,
        'marlin' || 'swordfish' => BodyPlan.billfish,
        'greatwhite' => BodyPlan.shark,
        'halibut' => BodyPlan.flat,
        'squid' => BodyPlan.cephalopod,
        'coelacanth' => BodyPlan.lobefin,
        _ => BodyPlan.roundfish,
      };

  /// What a shadow of this class of animal probably is, when the species is
  /// still withheld. `huge` things in the water are sharks and billfish far
  /// more often than they are mackerel.
  static BodyPlan fromShadow(String shadow, String style) {
    if (style == 'sounder') {
      return shadow == 'huge' ? BodyPlan.cephalopod : BodyPlan.flat;
    }
    if (style == 'jumper') return BodyPlan.billfish;
    if (style == 'runner') {
      return shadow == 'huge' ? BodyPlan.shark : BodyPlan.tuna;
    }
    return shadow == 'small' ? BodyPlan.torpedo : BodyPlan.roundfish;
  }
}

/// A body and the fins hanging off it, kept apart on purpose.
///
/// Folding fins into the outline as extra sub-paths looked fine until one
/// overlapped the body: non-zero winding then SUBTRACTS it, and the fish gets a
/// triangular hole punched through its flank. Separate paths cannot do that,
/// and it also lets the belly gradient clip to the body alone, which is what it
/// wanted anyway.
class FishShape {
  const FishShape(this.body, this.fins);

  final Path body;
  final List<Path> fins;
}

/// Builds the outline, nose pointing along +x.
///
/// [beat] is -1..1, the tail's swing. [bank] is -1..1, how far it is rolling —
/// a banking fish shows you less of its flank, which is what the height squeeze
/// is doing.
FishShape fishBody(BodyPlan plan, double length,
    {required double beat, double bank = 0}) {
  final l = length;
  final squeeze = 1 - bank.abs() * 0.55;
  return switch (plan) {
    BodyPlan.torpedo => _torpedo(l, beat, squeeze),
    BodyPlan.tuna => _tuna(l, beat, squeeze),
    BodyPlan.billfish => _billfish(l, beat, squeeze),
    BodyPlan.shark => _shark(l, beat, squeeze),
    BodyPlan.flat => _flat(l, beat, squeeze),
    BodyPlan.cephalopod => _cephalopod(l, beat, squeeze),
    BodyPlan.lobefin => _lobefin(l, beat, squeeze),
    BodyPlan.roundfish => _roundfish(l, beat, squeeze),
  };
}

// ---------------------------------------------------------------------------
// The plans. Each is drawn nose-first along +x, centred on the origin, so the
// scene can rotate and mirror them without knowing anything about the species.
// ---------------------------------------------------------------------------

FishShape _roundfish(double l, double beat, double sq) {
  final h = l * 0.32 * sq;
  final s = beat * l * 0.10;
  final body = Path()
    ..moveTo(l * 0.50, 0)
    ..cubicTo(l * 0.22, -h, l * -0.10, -h * 0.95, l * -0.30, -h * 0.26 + s)
    ..lineTo(l * -0.50, -h * 0.85 + s * 1.7)
    ..lineTo(l * -0.42, s * 1.7)
    ..lineTo(l * -0.50, h * 0.85 + s * 1.7)
    ..lineTo(l * -0.30, h * 0.26 + s)
    ..cubicTo(l * -0.10, h * 0.95, l * 0.22, h, l * 0.50, 0)
    ..close();
  return FishShape(body, [
    _dorsalTriangle(l, h, 0.12, -0.45, -1.55, -0.22),
    _pectoral(l, h, s),
  ]);
}

FishShape _torpedo(double l, double beat, double sq) {
  // Slimmer, and the tail is deeply forked — the shape of something built to
  // keep swimming rather than to manoeuvre.
  final h = l * 0.22 * sq;
  final s = beat * l * 0.11;
  final body = Path()
    ..moveTo(l * 0.52, 0)
    ..cubicTo(l * 0.24, -h, l * -0.06, -h * 0.90, l * -0.28, -h * 0.22 + s)
    ..lineTo(l * -0.50, -h * 1.15 + s * 1.9)
    ..lineTo(l * -0.38, s * 1.9)
    ..lineTo(l * -0.50, h * 1.15 + s * 1.9)
    ..lineTo(l * -0.28, h * 0.22 + s)
    ..cubicTo(l * -0.06, h * 0.90, l * 0.24, h, l * 0.52, 0)
    ..close();
  return FishShape(body, [
    _dorsalTriangle(l, h, 0.06, -0.50, -1.70, -0.26),
    _pectoral(l, h, s),
  ]);
}

FishShape _tuna(double l, double beat, double sq) {
  // Hard shoulders forward, a narrow wrist, and a stiff crescent tail. Plus
  // the row of little finlets that nothing else in the sea has.
  final h = l * 0.30 * sq;
  final s = beat * l * 0.07; // a stiff tail beats through a smaller arc
  final path = Path()
    ..moveTo(l * 0.50, 0)
    ..cubicTo(l * 0.30, -h * 1.05, l * 0.02, -h, l * -0.26, -h * 0.16 + s)
    // Crescent: swept back to points rather than a fork.
    ..quadraticBezierTo(
        l * -0.40, -h * 1.5 + s * 1.8, l * -0.52, -h * 1.05 + s * 2.0)
    ..quadraticBezierTo(l * -0.40, s * 1.9, l * -0.52, h * 1.05 + s * 2.0)
    ..quadraticBezierTo(
        l * -0.40, h * 1.5 + s * 1.8, l * -0.26, h * 0.16 + s)
    ..cubicTo(l * 0.02, h, l * 0.30, h * 1.05, l * 0.50, 0)
    ..close();
  final finlets = Path();
  for (var i = 0; i < 4; i++) {
    final x = l * (-0.06 - i * 0.045);
    finlets
      ..moveTo(x, -h * 0.58)
      ..lineTo(x - l * 0.02, -h * 0.86)
      ..lineTo(x - l * 0.035, -h * 0.55)
      ..close();
  }
  return FishShape(path, [
    _dorsalTriangle(l, h, 0.16, -0.50, -1.75, -0.06),
    _pectoral(l, h, s),
    finlets,
  ]);
}

FishShape _billfish(double l, double beat, double sq) {
  // The bill is a third of the animal, and the sail is unmistakable even as a
  // shadow — which is exactly what you want from something that jumps.
  final h = l * 0.24 * sq;
  final s = beat * l * 0.09;
  final body = Path()
    ..moveTo(l * 0.72, 0) // tip of the bill
    ..lineTo(l * 0.30, -h * 0.16)
    ..cubicTo(l * 0.16, -h * 0.9, l * -0.04, -h, l * -0.28, -h * 0.20 + s)
    ..lineTo(l * -0.50, -h * 1.20 + s * 1.9)
    ..lineTo(l * -0.38, s * 1.9)
    ..lineTo(l * -0.50, h * 1.20 + s * 1.9)
    ..lineTo(l * -0.28, h * 0.20 + s)
    ..cubicTo(l * -0.04, h, l * 0.16, h * 0.9, l * 0.30, h * 0.16)
    ..close();
  // The sail: a long standing dorsal, not a triangle.
  final sail = Path()
    ..moveTo(l * 0.22, -h * 0.55)
    ..quadraticBezierTo(l * 0.10, -h * 2.5, l * -0.06, -h * 2.3)
    ..quadraticBezierTo(l * -0.18, -h * 2.1, l * -0.24, -h * 0.5)
    ..close();
  return FishShape(body, [sail, _pectoral(l, h, s)]);
}

FishShape _shark(double l, double beat, double sq) {
  // Heterocercal tail — the top lobe much longer than the bottom — plus that
  // tall first dorsal. Nothing else reads as "shark" so immediately.
  final h = l * 0.26 * sq;
  final s = beat * l * 0.10;
  final body = Path()
    ..moveTo(l * 0.52, -h * 0.05)
    ..cubicTo(l * 0.26, -h * 1.0, l * -0.04, -h * 0.95, l * -0.30, -h * 0.22 + s)
    ..lineTo(l * -0.56, -h * 1.55 + s * 1.8) // long upper lobe
    ..lineTo(l * -0.40, s * 1.8)
    ..lineTo(l * -0.50, h * 0.72 + s * 1.8) // short lower lobe
    ..lineTo(l * -0.30, h * 0.20 + s)
    ..cubicTo(l * -0.04, h * 0.92, l * 0.26, h * 0.85, l * 0.52, -h * 0.05)
    ..close();
  // First dorsal, tall and raked; pectorals long and stiff — they do not flap.
  final dorsal = Path()
    ..moveTo(l * 0.14, -h * 0.60)
    ..lineTo(l * -0.02, -h * 2.15)
    ..lineTo(l * -0.20, -h * 0.55)
    ..close();
  final pec = Path()
    ..moveTo(l * 0.16, h * 0.35)
    ..lineTo(l * -0.10, h * 1.75)
    ..lineTo(l * -0.02, h * 0.35)
    ..close();
  return FishShape(body, [dorsal, pec]);
}

FishShape _flat(double l, double beat, double sq) {
  // Seen from the side a flatfish is a disc with a fringe. It barely tapers,
  // and the fin runs the entire way round, which is the whole read.
  final h = l * 0.46 * sq;
  final s = beat * l * 0.05;
  final body = Path()
    ..moveTo(l * 0.46, -h * 0.10)
    ..cubicTo(l * 0.30, -h, l * -0.16, -h * 1.05, l * -0.38, -h * 0.30 + s)
    ..quadraticBezierTo(l * -0.52, s, l * -0.38, h * 0.30 + s)
    ..cubicTo(l * -0.16, h * 1.05, l * 0.30, h, l * 0.46, h * 0.10)
    ..close();
  // The fringing fin, as a scalloped band just inside the outline.
  final fringe = Path()
    ..moveTo(l * 0.30, -h * 0.86)
    ..cubicTo(l * 0.05, -h * 1.02, l * -0.20, -h * 0.95, l * -0.34, -h * 0.34)
    ..lineTo(l * -0.28, -h * 0.30)
    ..cubicTo(l * -0.16, -h * 0.82, l * 0.06, -h * 0.88, l * 0.30, -h * 0.74)
    ..close();
  return FishShape(body, [fringe]);
}

FishShape _cephalopod(double l, double beat, double sq) {
  // Mantle forward, fins at the pointed end, and a fistful of arms trailing.
  // Drawn nose-first like everything else so the scene can treat it the same,
  // even though a squid swims backwards — the arms are what you see coming.
  final h = l * 0.20 * sq;
  final s = beat * l * 0.06;
  final body = Path()
    ..moveTo(l * -0.52, s * 1.4) // tip of the mantle
    ..quadraticBezierTo(l * -0.30, -h * 1.05, l * 0.06, -h * 0.95)
    ..quadraticBezierTo(l * 0.24, -h * 0.85, l * 0.28, -h * 0.30)
    ..lineTo(l * 0.28, h * 0.30)
    ..quadraticBezierTo(l * 0.24, h * 0.85, l * 0.06, h * 0.95)
    ..quadraticBezierTo(l * -0.30, h * 1.05, l * -0.52, s * 1.4)
    ..close();
  // The two triangular fins on the mantle's point.
  final fins = Path()
    ..moveTo(l * -0.30, -h * 0.55)
    ..lineTo(l * -0.56, -h * 1.5 + s)
    ..lineTo(l * -0.44, -h * 0.2 + s)
    ..close()
    ..moveTo(l * -0.30, h * 0.55)
    ..lineTo(l * -0.56, h * 1.5 + s)
    ..lineTo(l * -0.44, h * 0.2 + s)
    ..close();
  // Arms, fanning and curling.
  final arms = Path();
  for (var i = 0; i < 6; i++) {
    final spread = (i / 5 - 0.5) * 2; // -1..1
    final curl = math.sin(beat * math.pi + i) * l * 0.06;
    arms
      ..moveTo(l * 0.26, h * 0.5 * spread)
      ..quadraticBezierTo(
        l * 0.50,
        h * 1.1 * spread + curl,
        l * 0.70,
        h * 1.6 * spread + curl * 1.6,
      )
      ..quadraticBezierTo(
        l * 0.48,
        h * 0.95 * spread + curl,
        l * 0.26,
        h * 0.5 * spread + h * 0.12,
      )
      ..close();
  }
  return FishShape(body, [fins, arms]);
}

FishShape _lobefin(double l, double beat, double sq) {
  // Heavy, blunt, and wrong-looking on purpose: the fins are on stalks and the
  // tail has a third little lobe sticking out of the middle of it.
  final h = l * 0.34 * sq;
  final s = beat * l * 0.07;
  final body = Path()
    ..moveTo(l * 0.46, -h * 0.12)
    ..cubicTo(l * 0.26, -h * 1.02, l * -0.06, -h * 0.98, l * -0.30, -h * 0.34 + s)
    ..lineTo(l * -0.46, -h * 0.80 + s * 1.5)
    ..lineTo(l * -0.42, -h * 0.16 + s * 1.5)
    ..lineTo(l * -0.60, s * 1.6) // the odd middle lobe
    ..lineTo(l * -0.42, h * 0.16 + s * 1.5)
    ..lineTo(l * -0.46, h * 0.80 + s * 1.5)
    ..lineTo(l * -0.30, h * 0.34 + s)
    ..cubicTo(l * -0.06, h * 0.98, l * 0.26, h * 1.02, l * 0.46, h * 0.12)
    ..close();
  // Lobed fins on fleshy stalks, top and bottom.
  final lobes = Path();
  for (final sign in const [-1.0, 1.0]) {
    for (final x in const [0.02, -0.20]) {
      lobes
        ..moveTo(l * x, sign * h * 0.80)
        ..quadraticBezierTo(l * (x - 0.06), sign * h * 1.35, l * (x - 0.14),
            sign * h * 1.55)
        ..quadraticBezierTo(l * (x - 0.06), sign * h * 1.15, l * (x - 0.06),
            sign * h * 0.78)
        ..close();
    }
  }
  return FishShape(body, [lobes]);
}

// -- shared bits -------------------------------------------------------------

Path _dorsalTriangle(
        double l, double h, double x0, double y0, double peak, double x1) =>
    Path()
      ..moveTo(l * x0, h * y0)
      ..lineTo(l * (x0 - 0.16), h * peak)
      ..lineTo(l * x1, h * -0.40)
      ..close();

Path _pectoral(double l, double h, double s) => Path()
  ..moveTo(l * 0.14, h * 0.30)
  ..lineTo(l * -0.04, h * 1.20 - s * 0.6)
  ..lineTo(l * -0.12, h * 0.28)
  ..close();
