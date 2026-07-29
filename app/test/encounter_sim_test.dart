import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_game/features/fishing/domain/encounter_sim.dart';

/// Is the new fight actually a game?
///
/// The old one could be checked by asking whether a duty cycle was achievable.
/// This one is a reading contest, so the questions are different and harder:
///
///   * can a player who reads the fish win, and one who cannot, lose?
///   * does the ROD move that line, rather than the fish being flatly easy or
///     flatly impossible? A rod ladder that buys nothing was the exact bug the
///     old model was written to avoid, and it is just as easy to reintroduce.
///   * do the four styles genuinely differ, or is every fish the same fight
///     with a different word on screen?
void main() {
  // A middling fish. `readMs` is the dial everything else is measured against.
  EncounterProfile profile({
    FightStyle style = FightStyle.scrapper,
    double readMs = 900,
    int moves = 6,
    double stamina = 14000,
    int grace = 1,
  }) =>
      EncounterProfile(
        style: style,
        staminaMs: stamina,
        moves: moves,
        readMs: readMs,
        tellMs: 550,
        holdMs: 700,
        // Fractions of the fish's total fight. Reads do the heavy lifting;
        // pumping is a trickle, so it cannot substitute for reading.
        gainPerPump: 0.025,
        lossOnMiss: 0.08,
        staminaPerRead: 1 / (moves - 1),
        graceMisses: grace,
      );

  group('the read window is the difficulty', () {
    test('a short window beats a player a long one would not', () {
      final tight = _rate(profile(readMs: 380), (s) => _human(seed: s, reactionMs: 420));
      final roomy = _rate(profile(readMs: 1500), (s) => _human(seed: s, reactionMs: 420));

      expect(tight.landed, lessThan(0.35),
          reason: 'a hand line has to be genuinely hard');
      expect(roomy.landed, greaterThan(0.85),
          reason: 'and the best rod in the game has to feel like mastery');
    });

    test('the rod ladder moves the win rate monotonically', () {
      // Six rod tiers, each buying reaction time. Nothing else changes.
      const windows = [420.0, 620.0, 820.0, 1020.0, 1240.0, 1500.0];
      final rates = [
        for (final w in windows) _rate(profile(readMs: w), (s) => _human(seed: s)).landed,
      ];
      for (var i = 1; i < rates.length; i++) {
        expect(rates[i], greaterThanOrEqualTo(rates[i - 1] - 0.02),
            reason: 'tier ${i + 1} must not be worse than tier $i: $rates');
      }
      expect(rates.last - rates.first, greaterThan(0.35),
          reason: 'the ladder has to be worth climbing: $rates');
    });

    test('a beginner fish on a beginner rod is still a fight', () {
      // The complaint that started this redesign: the early game was free.
      // A small fish with a hand line should be winnable but far from certain.
      final r = _rate(
        profile(readMs: 520, moves: 4, stamina: 8000),
        (s) => _human(seed: s, reactionMs: 430),
      );
      expect(r.landed, greaterThan(0.30), reason: 'not hopeless');
      expect(r.landed, lessThan(0.85), reason: 'and not free either');
    });
  });

  group('reading beats not reading', () {
    test('someone who answers correctly lands it; someone mashing does not', () {
      final f = profile();
      final read = _rate(f, (s) => _human(seed: s, reactionMs: 400));
      final mash = _rate(f, (s) => _alwaysPump);
      final panic = _rate(f, (s) => _alwaysGiveLine);

      expect(read.landed, greaterThan(0.75));
      expect(mash.landed, lessThan(0.15),
          reason: 'pumping through a jump has to lose the fish');
      expect(panic.landed, lessThan(0.30),
          reason: 'one answer to everything cannot be a strategy');
    });

    test('score reflects how cleanly it was read, not how long it took', () {
      final f = profile(grace: 99); // survive, so the score is the only signal
      expect(_rate(f, (s) => _human(seed: s, reactionMs: 380)).meanScore, greaterThan(0.85));
      expect(_rate(f, (s) => _alwaysPump).meanScore, lessThan(0.45));
    });
  });

  group('the styles are different fish', () {
    test('each style leans on its own repertoire', () {
      for (final style in FightStyle.values) {
        final counts = <Move, int>{};
        for (var seed = 0; seed < 200; seed++) {
          final sim =
              EncounterSim(profile(style: style), random: math.Random(seed));
          for (final h in sim.hazards) {
            counts[h.move] = (counts[h.move] ?? 0) + 1;
          }
        }
        // Everything it throws must be in its repertoire...
        for (final m in counts.keys) {
          expect(style.repertoire, contains(m), reason: '$style threw $m');
        }
        // ...and the move it repeats must actually dominate.
        final signature = style.repertoire.first;
        final top =
            counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
        expect(top, signature,
            reason: '$style should mostly $signature, got $counts');
      }
    });

    test('a runner and a sounder are not answered the same way', () {
      // The point of styles: the counter that beats one loses to the other.
      expect(Move.run.answer, isNot(Move.sound.answer));
      expect(Move.jump.answer, isNot(Move.sound.answer));
      // ...but head-shaking shares an answer on purpose, so the player learns
      // two rules rather than six.
      expect(Move.thrash.answer, Move.jump.answer);
      expect(Move.bore.answer, Move.sound.answer);
    });
  });

  group('the shape of the timeline', () {
    test('hazards never collide', () {
      final f = profile(moves: 8);
      for (var seed = 0; seed < 300; seed++) {
        final sim = EncounterSim(f, random: math.Random(seed));
        for (var i = 1; i < sim.hazards.length; i++) {
          final gap = sim.hazards[i].at - sim.hazards[i - 1].at;
          expect(gap, greaterThan(f.tellMs + f.readMs),
              reason: 'two tells at once is noise, not difficulty');
        }
      }
    });

    test('a tell always precedes the window it belongs to', () {
      final sim = EncounterSim(profile(), random: math.Random(1));
      final first = sim.hazards.first;
      var sawTell = false;
      while (!sim.isOver && sim.elapsedMs < first.at + 400) {
        sim.step(16, holding: Counter.pump);
        if (sim.telling) sawTell = true;
      }
      expect(sawTell, isTrue,
          reason: 'the fish must show you it is coming before it commits');
    });

    test('losing it slack throws the hook; losing it tight breaks you off', () {
      // The two failures read differently because they ARE different mistakes,
      // and which one you made follows from what you did, not from what would
      // have worked.
      final f = profile(grace: 0);

      // Giving line to a fish that is not running puts slack in it.
      expect(_play(f, _alwaysGiveLine, seed: 5), EncounterEnd.threwTheHook);

      // Pumping through everything keeps it loaded until something lets go.
      expect(_play(f, _alwaysPump, seed: 5), EncounterEnd.brokeOff);
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

typedef _Policy = Counter Function(EncounterSim sim, double dtMs);

/// Someone who reads the fish, but not instantly and not identically twice.
///
/// The reaction time is drawn fresh for every hazard. A FIXED reaction time
/// makes the whole model a step function — every hazard is either always
/// answered or never answered — and a step function cannot show a rod ladder
/// as anything but a cliff. Spread is what turns "the window is 200ms longer"
/// into "you get away with it more often", which is the thing being bought.
_Policy _human({int seed = 0, double reactionMs = 420, double spread = 150}) {
  // Seeded per TRIAL, not once: a single fixed seed makes every trial in a
  // batch the identical fight, which silently turns a 240-trial win rate into
  // a coin that only ever reads 0.0 or 1.0.
  final rng = math.Random(9000 + seed);
  Move? watching;
  var budget = 0.0;
  var since = 0.0;
  return (sim, dtMs) {
    if (!sim.awaitingAnswer) {
      watching = null;
      return Counter.pump;
    }
    if (watching != sim.move) {
      watching = sim.move;
      budget = reactionMs + (rng.nextDouble() * 2 - 1) * spread;
      since = 0;
    }
    since += dtMs;
    return since >= budget ? sim.move.answer : Counter.pump;
  };
}

Counter _alwaysPump(EncounterSim sim, double dtMs) => Counter.pump;

Counter _alwaysGiveLine(EncounterSim sim, double dtMs) => Counter.giveLine;

class _Outcome {
  const _Outcome(this.landed, this.meanScore);
  final double landed;
  final double meanScore;
}

EncounterEnd _play(EncounterProfile f, _Policy policy, {required int seed}) {
  final sim = EncounterSim(f, random: math.Random(seed));
  while (!sim.isOver && sim.elapsedMs < f.staminaMs * 4) {
    sim.step(16, holding: policy(sim, 16));
  }
  return sim.end;
}

/// [policy] is rebuilt per trial and handed that trial's seed, so both the
/// fish's timeline and the player's reactions vary across the batch.
_Outcome _rate(EncounterProfile f, _Policy Function(int seed) policy,
    {int trials = 240}) {
  var wins = 0;
  var score = 0.0;
  for (var i = 0; i < trials; i++) {
    final sim = EncounterSim(f, random: math.Random(i));
    final p = policy(i);
    while (!sim.isOver && sim.elapsedMs < f.staminaMs * 4) {
      sim.step(16, holding: p(sim, 16));
    }
    if (sim.end == EncounterEnd.landed) wins++;
    score += sim.score;
  }
  return _Outcome(wins / trials, score / trials);
}
