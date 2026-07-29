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
}

typedef _Policy = bool Function(FightSim sim, bool holding);

/// Someone who knows what they are doing: winds until the line is nearly at the
/// top of the band, eases off until it is nearly at the bottom, and re-decides
/// on a human cadence rather than every frame.
bool _skilled(FightSim sim, bool holding) {
  final f = sim.fight;
  if (sim.surging) return false;
  if (holding) return sim.tension < f.bandHigh - 0.04;
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
