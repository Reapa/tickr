import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_game/features/fishing/presentation/fight_scene.dart';
import 'package:trading_game/features/fishing/presentation/sea.dart';

/// The fight scene is a few hundred lines of geometry with no compiler checking
/// that any of it is in frame. It cannot be asserted to look good, but it can be
/// asserted to *paint* — every phase, every extreme of every input, including
/// the degenerate sizes a web canvas will hand it during a resize.
///
/// The bugs this is here to catch are the ones that already happened once:
/// dividing by a zero-width canvas, indexing the line's sample list past its
/// end, and NaN leaking out of a clamp into a Path.
void main() {
  void paint(
    Size size, {
    double t = 4,
    double tension = 0.5,
    double progress = 0.4,
    double surge = 0,
    double strain = 0,
    bool hooked = true,
    bool bobber = false,
    double bobberDip = 0,
    double breach = 0,
    bool snapped = false,
  }) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);
    FightScene(
      t: t,
      palette: SeaPalette.lerp(SeaPalette.open, SeaPalette.strained, strain),
      tension: tension,
      progress: progress,
      surge: surge,
      strain: strain,
      fishScale: 0.62,
      hooked: hooked,
      reeling: true,
      bobber: bobber,
      bobberDip: bobberDip,
      breach: breach,
      snapped: snapped,
      fx: FightFx(),
      shake: Offset.zero,
    ).paint(canvas, size);
    recorder.endRecording().dispose();
  }

  const phone = Size(390, 780);

  test('paints every phase of a fight', () {
    expect(
      () {
        paint(phone, hooked: false, bobber: true, progress: 0); // waiting
        paint(phone, hooked: false, bobber: true, bobberDip: 1); // the bite
        paint(phone, tension: 0.45, progress: 0.2); // in the band
        paint(phone, tension: 0.8, surge: 1, strain: 0.3); // running
        paint(phone, tension: 0.99, strain: 1); // about to go
        paint(phone, tension: 0, progress: 0.6, snapped: true); // gone
        paint(phone, progress: 1, breach: 0.75); // the leap
      },
      returnsNormally,
    );
  });

  test('survives the sizes a resizing web canvas hands it', () {
    for (final size in const [
      Size(1, 1),
      Size(0, 0),
      Size(2000, 300), // wide and short: the horizon and surface nearly collide
      Size(200, 2000),
    ]) {
      expect(() => paint(size), returnsNormally, reason: '$size');
    }
  });

  test('tension outside 0..1 does not escape into the geometry', () {
    expect(() {
      paint(phone, tension: -1);
      paint(phone, tension: 5);
      paint(phone, progress: -0.5);
      paint(phone, progress: 2);
    }, returnsNormally);
  });

  group('FightFx', () {
    test('particles expire rather than accumulating forever', () {
      final fx = FightFx()..surfaceY = 300;
      for (var i = 0; i < 40; i++) {
        fx.splash(const Offset(100, 300), power: 1);
      }
      expect(fx.drops, isNotEmpty);
      expect(fx.rings.length, lessThanOrEqualTo(9),
          reason: 'rings are capped so a long fight cannot flood the frame');

      // Two seconds of nothing but time.
      for (var i = 0; i < 125; i++) {
        fx.step(16, surfaceY: 300, reelRate: 0);
      }
      expect(fx.drops, isEmpty);
      expect(fx.rings, isEmpty);
    });

    test('bubbles are rate-limited and pop at the surface', () {
      final fx = FightFx();
      for (var i = 0; i < 200; i++) {
        fx.trickleBubbles(const Offset(100, 600), 1);
        fx.step(16, surfaceY: 300, reelRate: 0);
      }
      expect(fx.bubbles.length, lessThanOrEqualTo(27));
      expect(fx.bubbles.every((b) => b.y >= 300), isTrue);
    });

    test('the reel turns both ways', () {
      final fx = FightFx();
      fx.step(1000, surfaceY: 0, reelRate: 8);
      expect(fx.reelAngle, closeTo(8, 0.001));
      fx.step(1000, surfaceY: 0, reelRate: -8);
      expect(fx.reelAngle, closeTo(0, 0.001));
    });
  });
}
