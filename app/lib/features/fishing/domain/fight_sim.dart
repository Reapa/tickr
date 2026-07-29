import 'dart:math' as math;

import 'fishery.dart';

/// How a fight ended.
enum FightEnd { none, landed, snapped, ranOut, snagged }

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

    // Dives sit anywhere; they ask the opposite of a run, and overlapping one
    // with a run is a legitimately nasty moment rather than an unfair one,
    // because winding through both is still the right answer.
    dives = List.generate(fight.dives, (_) {
      final start = stamina * (0.20 + _rng.nextDouble() * 0.55);
      return (start: start, end: start + fight.diveMs);
    })
      ..sort((a, b) => a.start.compareTo(b.start));

    // Snags are different: they demand a TIGHT line while a run demands a
    // slack one, so an overlap would be unsurvivable rather than difficult.
    // They are placed only in gaps clear of every run.
    snags = _scheduleSnags(stamina);
  }

  /// Finds windows for the snags that do not touch a run. Falls back to fewer
  /// snags rather than an overlapping one — a hazard you cannot answer is not
  /// a mechanic.
  List<({double start, double end})> _scheduleSnags(double stamina) {
    final out = <({double start, double end})>[];
    if (!fight.hasSnags) return out;
    final width = fight.snagMs.toDouble();
    for (var i = 0; i < fight.snags; i++) {
      for (var attempt = 0; attempt < 24; attempt++) {
        final start = stamina * (0.18 + _rng.nextDouble() * 0.60);
        final end = start + width;
        final clashes = runs.any((r) => start < r.end + 400 && end + 400 > r.start) ||
            out.any((s) => start < s.end + 300 && end + 300 > s.start);
        if (!clashes) {
          out.add((start: start, end: end));
          break;
        }
      }
    }
    return out..sort((a, b) => a.start.compareTo(b.start));
  }

  final FightProfile fight;
  final math.Random _rng;

  /// When the fish surges. It costs line whether or not you are winding.
  late final List<({double start, double end})> runs;

  /// When it sounds. Progress bleeds; tension does not rise.
  late final List<({double start, double end})> dives;

  /// When it is making for structure. Keep the line loaded or lose it.
  late final List<({double start, double end})> snags;

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

  /// Whether the fish is sounding right now, and how hard.
  bool diving = false;
  double diveIntensity = 0;

  /// Whether it is making for structure right now, and how close it is to
  /// getting there. [snagDanger] only climbs while the line is slack.
  bool snagging = false;
  double snagDanger = 0;

  /// The working band's ceiling, which falls as the leader wears.
  double get bandHigh =>
      (fight.bandHigh - fight.bandDecay * _wear).clamp(0.2, 1.0);

  /// 0..1 — how far through the fight's stamina we are.
  double get _wear => fight.staminaMs <= 0
      ? 0
      : (elapsedMs / fight.staminaMs).clamp(0.0, 1.0);

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

    // Sounding: it puts its head down and simply goes. No tension of its own,
    // so unlike a run the answer is to wind through it and eat the load.
    diveIntensity = 0;
    for (final d in dives) {
      if (elapsedMs >= d.start && elapsedMs <= d.end) {
        final into = elapsedMs - d.start;
        final left = d.end - elapsedMs;
        diveIntensity = math.max(diveIntensity,
            (math.min(into, left) / surgeRampMs).clamp(0.0, 1.0));
      }
    }
    diving = diveIntensity > 0;

    // Structure. The danger only builds while the line is slack, so this is
    // answerable: lean on it and the fish turns.
    snagging = snags.any((s) => elapsedMs >= s.start && elapsedMs <= s.end);
    if (snagging) {
      if (tension < fight.bandLow) {
        snagDanger += dt / (fight.snagMs / 1000.0) * 1.35;
      } else {
        snagDanger -= dt * 0.9;
      }
      snagDanger = snagDanger.clamp(0.0, 1.0);
    } else {
      snagDanger = math.max(0, snagDanger - dt * 1.6);
    }

    // Past the top of the band YOUR winding loads the line much faster, so the
    // gap between the band and a snap is a warning rather than spare capacity.
    // The fish's own surge is deliberately not multiplied — you did not choose
    // it, and punishing it would make runs unplayable rather than tense.
    final load = fight.strength * (tension > bandHigh ? fight.overMult : 1.0);

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
    if (diving) {
      progress -= fight.divePull * diveIntensity * dt;
    }

    tension = tension.clamp(0.0, 1.2);
    progress = progress.clamp(0.0, 1.0);

    _totalMs += dtMs;
    if (tension >= fight.bandLow && tension <= bandHigh) {
      _inBandMs += dtMs;
    }

    if (tension >= 1.0) {
      end = FightEnd.snapped;
    } else if (snagDanger >= 1.0) {
      end = FightEnd.snagged;
    } else if (progress >= 1.0) {
      end = FightEnd.landed;
    } else if (elapsedMs > fight.staminaMs) {
      end = FightEnd.ranOut;
    }
  }

  /// A hook set cleanly starts with the line already part-loaded.
  void setHook() => tension = fight.bandLow * 0.6;
}
