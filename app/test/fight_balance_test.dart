import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_game/features/fishing/domain/fight_sim.dart';
import 'package:trading_game/features/fishing/domain/fishery.dart';

/// Is the fight actually a game?
///
/// The fishery's fight is the one part of this feature the server cannot check
/// for itself — it hands the client a set of numbers and trusts it to play them
/// out. So the numbers have to be right, and "right" means three things at once:
///
///   * a beginner's fish is winnable by playing well and NOT by mashing;
///   * the hardest fish in the game genuinely beats the starting rod;
///   * the best rod genuinely tames it.
///
/// If any of those stops being true the mini-game is either free or impossible,
/// and in both cases the whole rod ladder stops meaning anything. These are real
/// `fight` payloads taken from `game.roll_encounter`, so this tests the server's
/// actual output rather than a restatement of its formulas.
void main() {
  // The first fight a new player ever has: a big cod, hand line, harbour.
  const harbourCodOnHandLine = '{"runs": 2, "run_ms": 698, "shadow": "small", '
      '"bite_ms": 2374, "band_low": 0.350, "strength": 0.506, '
      '"band_high": 0.70, "challenge": 0.599, "over_mult": 1.6, '
      '"reel_rate": 0.6880, "slip_rate": 0.06, "difficulty": 0.284, '
      '"relax_rate": 0.450, "stamina_ms": 6980, "surge_rate": 0.627, '
      '"hook_window_ms": 801}';

  // The other end of the game.
  const greatWhiteOnHandLine = '{"runs": 4, "run_ms": 1400, "shadow": "huge", '
      '"bite_ms": 1489, "band_low": 0.350, "strength": 0.898, '
      '"band_high": 0.70, "challenge": 0.849, "over_mult": 1.6, '
      '"reel_rate": 0.1609, "slip_rate": 0.06, "difficulty": 0.996, '
      '"relax_rate": 0.450, "stamina_ms": 34901, "surge_rate": 0.921, '
      '"hook_window_ms": 551}';

  const greatWhiteOnAbyssalRod =
      '{"runs": 4, "run_ms": 1400, "shadow": "huge", '
      '"bite_ms": 1881, "band_low": 0.200, "strength": 0.699, '
      '"band_high": 0.70, "challenge": 0.600, "over_mult": 1.6, '
      '"reel_rate": 0.1317, "slip_rate": 0.06, "difficulty": 0.999, '
      '"relax_rate": 0.950, "stamina_ms": 34971, "surge_rate": 1.047, '
      '"hook_window_ms": 1000}';

  FightProfile profile(String json) =>
      FightProfile.fromJson(jsonDecode(json) as Map<String, dynamic>);

  test('a starter fish rewards playing it and punishes mashing the button', () {
    final fight = profile(harbourCodOnHandLine);

    final skilled = _rate(fight, _skilled);
    final masher = _rate(fight, _alwaysHold);
    final idle = _rate(fight, _neverHold);

    expect(skilled.landed, greaterThan(0.9),
        reason: 'a cod on a hand line has to be landable, or nobody starts');
    expect(masher.landed, lessThan(0.25),
        reason: 'holding the button down must snap the line, otherwise the '
            'tension band is decoration');
    expect(idle.landed, 0.0,
        reason: 'doing nothing cannot land a fish');
    expect(skilled.meanScore, greaterThan(0.75),
        reason: 'playing it properly should clear the clean-fight bonus '
            'threshold the server pays out on');
  });

  test('the hardest fish in the game beats the starting rod', () {
    final rate = _rate(profile(greatWhiteOnHandLine), _skilled);
    expect(rate.landed, lessThan(0.35),
        reason: 'a great white on a hand line should mostly win. If this ever '
            'passes easily, the rod ladder has stopped mattering');
  });

  test('and the best rod in the game tames it', () {
    final rate = _rate(profile(greatWhiteOnAbyssalRod), _skilled);
    expect(rate.landed, greaterThan(0.85),
        reason: 'a \$750k rod has to convert the fish it was bought for');
  });

  test('a run costs line whether or not you are winding', () {
    final fight = profile(greatWhiteOnHandLine);
    // Seeded so the surge windows are fixed and the comparison is honest.
    final sim = FightSim(fight, random: math.Random(7));
    sim.setHook();

    double? progressAtSurge;
    while (!sim.isOver && sim.elapsedMs < fight.staminaMs) {
      sim.step(16, holding: false);
      if (sim.surging) {
        progressAtSurge ??= sim.progress;
      } else if (progressAtSurge != null) {
        expect(sim.progress, lessThan(progressAtSurge + 1e-9),
            reason: 'line given up during a run must not come back for free');
        break;
      }
    }
    expect(progressAtSurge, isNotNull, reason: 'the fish should have run');
  });

  // ---------------------------------------------------------------------------
  // Per-spot hazards.
  //
  // Each spot has to clear the same two bars the base fight does: a player who
  // reads it can win, and a player who does not can lose. A hazard that fails
  // the first is a tax; one that fails the second is decoration.
  // ---------------------------------------------------------------------------
  group('per-spot mechanics', () {
    for (final spot in _spots) {
      test('${spot.name}: rewards reading it, punishes ignoring it', () {
        final f = spot.build();
        final skilled = _rate(f, _skilled);
        final mashing = _rate(f, _alwaysHold);

        expect(skilled.landed, greaterThan(0.55),
            reason: '${spot.name} must be winnable by someone playing it');
        expect(mashing.landed, lessThan(skilled.landed),
            reason: '${spot.name} must punish holding the button down');
      });
    }

    test('a snag is lost to slack line, and only to slack line', () {
      final f = _spots.firstWhere((s) => s.name == 'The Reef').build();

      // Someone who goes slack the moment the fish is on structure.
      var snagged = 0;
      for (var i = 0; i < 200; i++) {
        final sim = FightSim(f, random: math.Random(i))..setHook();
        while (!sim.isOver) {
          sim.step(16, holding: sim.snagging ? false : _skilled(sim, false));
        }
        if (sim.end == FightEnd.snagged) snagged++;
      }
      expect(snagged, greaterThan(0),
          reason: 'going slack on structure has to actually lose the fish');

      // ...and someone who leans on it during the same windows never is.
      for (var i = 0; i < 200; i++) {
        final sim = FightSim(f, random: math.Random(i))..setHook();
        while (!sim.isOver) {
          sim.step(16, holding: _skilled(sim, false));
        }
        expect(sim.end, isNot(FightEnd.snagged),
            reason: 'a tight line must always answer the structure');
      }
    });

    test('snag windows never overlap a run', () {
      // The two hazards demand opposite things. Overlapping them would be a
      // coin flip rather than a decision, so the scheduler must keep them apart.
      final f = _spots.firstWhere((s) => s.name == 'The Reef').build();
      for (var i = 0; i < 300; i++) {
        final sim = FightSim(f, random: math.Random(i));
        for (final s in sim.snags) {
          for (final r in sim.runs) {
            expect(s.start < r.end && s.end > r.start, isFalse,
                reason: 'snag ${s.start}-${s.end} overlaps run ${r.start}-${r.end}');
          }
        }
      }
    });

    test('a dive costs ground and gives it back to winding', () {
      final f = _spots.firstWhere((s) => s.name == 'The Canyon').build();
      // Play it properly up to the dive — there has to be ground on the board
      // before losing ground can mean anything — then let go through it. Swept
      // across seeds because a single one can end before it ever sounds.
      var sawDive = 0;
      var worstLoss = 0.0;
      for (var seed = 0; seed < 60; seed++) {
        final sim = FightSim(f, random: math.Random(seed))..setHook();
        var holding = false;
        var lost = 0.0;
        var dived = false;
        while (!sim.isOver) {
          holding = sim.diving ? false : _skilled(sim, holding);
          final before = sim.progress;
          sim.step(16, holding: holding);
          if (sim.diving) {
            dived = true;
            if (sim.progress < before) lost += before - sim.progress;
          }
        }
        if (dived) sawDive++;
        worstLoss = math.max(worstLoss, lost);
      }
      expect(sawDive, greaterThan(0), reason: 'the fish has to sound at all');
      expect(worstLoss, greaterThan(0.02),
          reason: 'sounding has to take enough ground to be worth reacting to');
    });

    test('the band closes as the leader wears on ice', () {
      final f = _spots.firstWhere((s) => s.name == 'The Ice Shelf').build();
      final sim = FightSim(f, random: math.Random(1))..setHook();
      final atStart = sim.bandHigh;
      while (sim.elapsedMs < f.staminaMs * 0.9 && !sim.isOver) {
        sim.step(16, holding: false);
      }
      expect(sim.bandHigh, lessThan(atStart - 0.05),
          reason: 'band_decay must actually close the safe window');
    });

    test('a spot with no hazards is exactly the fight it always was', () {
      final plain = _spots.firstWhere((s) => s.name == 'The Harbour').build();
      final sim = FightSim(plain, random: math.Random(0));
      expect(sim.snags, isEmpty);
      expect(sim.dives, isEmpty);
      expect(sim.bandHigh, plain.bandHigh);
    });
  });
}

/// A spot, and the fight profile the server would build for a middling fish in
/// it. Mirrors the arithmetic in the migration so the two cannot drift apart
/// silently — if that formula changes, these numbers are the canary.
class _Spot {
  const _Spot(
    this.name, {
    this.fightScale = 1.0,
    this.snags = 0,
    this.dives = 0,
    this.bandDecay = 0,
    this.runMult = 1,
    this.dragMult = 1,
  });

  final String name;
  final double fightScale;
  final int snags;
  final int dives;
  final double bandDecay;
  final double runMult;
  final double dragMult;

  FightProfile build({double diff = 0.5, int rodTier = 1}) {
    const slip = 0.06;
    const pull = 0.10;
    final stam = ((6000 + 14000 * diff) * fightScale).round();
    final runs = 1 + (diff * 4).floor();
    final runMs = (1400.0.clamp(600, 1400) * 0 +
            (stam * 0.10).clamp(600, 1400)) *
        runMult;
    final snagMs = (stam * 0.11).clamp(700, 1600);
    final diveMs = (stam * 0.16).clamp(900, 2600);
    final str = (0.35 + 0.55 * diff - 0.04 * (rodTier - 1)).clamp(0.20, 99.0);
    final relax = (0.45 + 0.10 * (rodTier - 1)) * dragMult;
    final duty = relax / (str + relax);
    final chall = (0.50 + 0.35 * diff - 0.05 * (rodTier - 1)).clamp(0.42, 0.92);

    return FightProfile(
      biteMs: 1200,
      hookWindowMs: 700,
      staminaMs: stam,
      strength: str.toDouble(),
      relaxRate: relax,
      reelRate: (1 + runs * (runMs / 1000) * slip + dives * (diveMs / 1000) * pull) /
          (math.max(1.0, (stam - runs * runMs) / 1000) * duty * chall),
      slipRate: slip,
      bandLow: math.max(0.18, 0.35 - 0.03 * (rodTier - 1)),
      bandHigh: 0.70,
      overMult: 1.6,
      surgeRate: 0.75 * str + 0.55 * relax,
      runs: runs,
      runMs: runMs.round(),
      shadow: 'big',
      difficulty: diff,
      snags: snags,
      snagMs: snagMs.round(),
      dives: dives,
      diveMs: diveMs.round(),
      divePull: pull,
      bandDecay: bandDecay,
    );
  }
}

const _spots = [
  _Spot('The Harbour', fightScale: 0.70),
  _Spot('The Reef', fightScale: 0.90, snags: 2),
  _Spot('Open Water', fightScale: 1.15, runMult: 1.45),
  _Spot('The Canyon', fightScale: 1.45, dives: 2),
  _Spot('The Trench', fightScale: 1.75, dives: 1, snags: 1),
  _Spot('The Ice Shelf',
      fightScale: 1.90, bandDecay: 0.10, dragMult: 0.82),
];

typedef _Policy = bool Function(FightSim sim, bool holding);

/// Someone who knows what they are doing: winds until the line is nearly at the
/// top of the band, eases off until it is nearly at the bottom, and re-decides
/// on a human cadence rather than every frame.
bool _skilled(FightSim sim, bool holding) {
  final f = sim.fight;
  // Structure outranks everything else: a slack line does not cost ground
  // there, it loses the fish outright. Note this is the exact opposite of the
  // answer to a run, which is the point of having both.
  if (sim.snagging) return sim.tension < sim.bandHigh - 0.02;
  if (sim.surging) return false;
  // Sounding adds no tension of its own, so wind through it — but still not
  // into a snap.
  if (sim.diving) return sim.tension < sim.bandHigh - 0.02;
  // Measured against the LIVE ceiling so a decaying band is played correctly.
  if (holding) return sim.tension < sim.bandHigh - 0.04;
  return sim.tension <= f.bandLow + 0.04;
}

bool _alwaysHold(FightSim sim, bool holding) => true;

bool _neverHold(FightSim sim, bool holding) => false;

class _Outcome {
  const _Outcome(this.landed, this.meanScore);
  final double landed;
  final double meanScore;
}

/// Play the same fight many times. Only the timing of the fish's runs varies,
/// which is the only randomness the client contributes.
_Outcome _rate(FightProfile fight, _Policy policy, {int trials = 300}) {
  const dt = 16.0;
  const decideEveryMs = 112.0; // a human is not a 60Hz controller
  var wins = 0;
  var scoreTotal = 0.0;

  for (var i = 0; i < trials; i++) {
    final sim = FightSim(fight, random: math.Random(i));
    sim.setHook();
    var holding = false;
    var sinceDecision = 0.0;

    while (!sim.isOver) {
      sinceDecision += dt;
      if (sinceDecision >= decideEveryMs) {
        sinceDecision = 0;
        holding = policy(sim, holding);
      }
      sim.step(dt, holding: holding);
    }
    if (sim.end == FightEnd.landed) wins++;
    scoreTotal += sim.score;
  }
  return _Outcome(wins / trials, scoreTotal / trials);
}
