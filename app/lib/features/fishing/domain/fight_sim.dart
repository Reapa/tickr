import 'dart:math' as math;

import 'fishery.dart';

/// How a fight ended.
enum FightEnd { none, landed, snapped, ranOut }

/// The physics of one fight, with no Flutter in it.
///
/// Pulled out of the widget so the balance can actually be tested: whether a
/// fish is landable is a property of the server's numbers, not of the paint
/// code, and the only honest way to know a matchup is fair is to play it.
/// [FightPanel] owns the input and the pixels; this owns the rules.
class FightSim {
  FightSim(this.fight, {math.Random? random})
      : _rng = random ?? math.Random() {
    final stamina = fight.staminaMs.toDouble();
    runs = List.generate(fight.runs, (_) {
      final start = stamina * (0.15 + _rng.nextDouble() * 0.65);
      return (start: start, end: start + fight.runMs);
    })
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  final FightProfile fight;
  final math.Random _rng;

  /// When the fish surges. It costs line whether or not you are winding.
  late final List<({double start, double end})> runs;

  /// How long a run takes to reach full strength. A surge that switched on at
  /// full power was unreactable: a player mid-wind ate the whole thing before
  /// they could let go, so runs read as random death rather than a moment to
  /// play. Ramping it means the fish visibly *starts* to run and letting go
  /// promptly is rewarded.
  static const double surgeRampMs = 350;

  double tension = 0;
  double progress = 0;
  double elapsedMs = 0;
  bool surging = false;

  /// 0..1 — how far into its surge the fish is.
  double surgeIntensity = 0;

  double _inBandMs = 0;
  double _totalMs = 0;

  FightEnd end = FightEnd.none;

  /// Fraction of the fight spent inside the tension band. This is the only
  /// number the client reports that can move money, and the server clamps what
  /// it is worth.
  double get score =>
      _totalMs <= 0 ? 0 : (_inBandMs / _totalMs).clamp(0.0, 1.0);

  bool get isOver => end != FightEnd.none;

  /// Advance the fight. [holding] is whether the player is on the reel.
  void step(double dtMs, {required bool holding}) {
    if (isOver) return;
    final dt = dtMs / 1000.0;
    elapsedMs += dtMs;

    surgeIntensity = 0;
    for (final r in runs) {
      if (elapsedMs >= r.start && elapsedMs <= r.end) {
        final into = elapsedMs - r.start;
        final left = r.end - elapsedMs;
        surgeIntensity = math.max(
          surgeIntensity,
          (math.min(into, left) / surgeRampMs).clamp(0.0, 1.0),
        );
      }
    }
    surging = surgeIntensity > 0;

    // Past the top of the band YOUR winding loads the line much faster, so the
    // gap between the band and a snap is a warning rather than spare capacity.
    // The fish's own surge is deliberately not multiplied — you did not choose
    // it, and punishing it would make runs unplayable rather than tense.
    final load =
        fight.strength * (tension > fight.bandHigh ? fight.overMult : 1.0);

    if (holding) {
      tension += load * dt;
      progress += fight.reelRate * dt;
    } else {
      tension -= fight.relaxRate * dt;
    }

    if (surging) {
      tension += fight.surgeRate * surgeIntensity * dt;
      progress -= fight.slipRate * surgeIntensity * dt;
    }

    tension = tension.clamp(0.0, 1.2);
    progress = progress.clamp(0.0, 1.0);

    _totalMs += dtMs;
    if (tension >= fight.bandLow && tension <= fight.bandHigh) {
      _inBandMs += dtMs;
    }

    if (tension >= 1.0) {
      end = FightEnd.snapped;
    } else if (progress >= 1.0) {
      end = FightEnd.landed;
    } else if (elapsedMs > fight.staminaMs) {
      end = FightEnd.ranOut;
    }
  }

  /// A hook set cleanly starts with the line already part-loaded.
  void setHook() => tension = fight.bandLow * 0.6;
}
