/// The fight, as a contest of reading rather than a contest of holding.
///
/// The old fight was a single-axis duty cycle: keep one number inside a band.
/// However it was dressed, it was one decision made over and over, and it could
/// not express the difference between a marlin and a halibut because there was
/// only ever one right answer.
///
/// This one is a conversation. The fish does things — it runs, it jumps, it
/// shakes its head, it sounds for the bottom, it bores for structure — and each
/// of those has exactly one correct answer. It telegraphs before it commits,
/// and the length of that telegraph is what a rod actually buys you.
///
///   RUN      it is going, and fast          -> GIVE LINE
///   JUMP     it comes out of the water      -> BOW TO IT
///   THRASH   head shaking, boat-side        -> BOW TO IT
///   SOUND    it takes your line down        -> SIDE PRESSURE
///   BORE     it makes for structure         -> SIDE PRESSURE
///   WORK     it is tiring, nothing doing    -> PUMP, and gain line
///
/// Two moves share an answer on purpose. "Anything that shakes its head, drop
/// the tip" and "anything that takes you down or sideways, lever it" are two
/// rules a player can actually hold in their head, where six would just be a
/// lookup table.
///
/// Nothing in here is authoritative about money. The server fixes the fish and
/// the profile; this plays it out and reports whether it was landed and how
/// cleanly, exactly as the old simulation did.
library;

import 'dart:math' as math;

import '../../../core/json.dart';

/// What the fish is doing.
enum Move { work, run, jump, thrash, sound, bore }

/// What the angler is doing about it.
enum Counter { pump, giveLine, bow, sidePressure }

extension MoveInfo on Move {
  /// The one right answer. This is the whole game.
  Counter get answer => switch (this) {
        Move.work => Counter.pump,
        Move.run => Counter.giveLine,
        Move.jump => Counter.bow,
        Move.thrash => Counter.bow,
        Move.sound => Counter.sidePressure,
        Move.bore => Counter.sidePressure,
      };

  /// Whether this is something the fish springs on you, as opposed to the
  /// resting state you are free to work in.
  bool get isHazard => this != Move.work;

  /// What the player sees a beat before it commits.
  String get tell => switch (this) {
        Move.work => '',
        Move.run => 'THE SPOOL IS ABOUT TO GO',
        Move.jump => "IT'S COMING UP",
        Move.thrash => "IT'S SHAKING ITS HEAD",
        Move.sound => "IT'S PUTTING ITS HEAD DOWN",
        Move.bore => "IT'S MAKING FOR THE STRUCTURE",
      };

  String get label => switch (this) {
        Move.work => 'WORKING',
        Move.run => 'RUNNING',
        Move.jump => 'JUMPING',
        Move.thrash => 'THRASHING',
        Move.sound => 'SOUNDING',
        Move.bore => 'BORING FOR COVER',
      };
}

extension CounterInfo on Counter {
  String get label => switch (this) {
        Counter.pump => 'PUMP',
        Counter.giveLine => 'GIVE LINE',
        Counter.bow => 'BOW TO IT',
        Counter.sidePressure => 'SIDE PRESSURE',
      };
}

/// How a species fights. The style is sent instead of the name, so the fish is
/// still a shadow — but a shadow that behaves like something. Learning that a
/// fish which jumps twice and then sounds is a marlin is the catch log doing
/// its job.
enum FightStyle {
  /// Tuna, sharks. It simply goes, a long way, and you hang on.
  runner([Move.run, Move.run, Move.run, Move.thrash]),

  /// Marlin, salmon, swordfish. Airborne and vicious about it.
  jumper([Move.jump, Move.jump, Move.thrash, Move.run]),

  /// Halibut, squid, coelacanth. Dead weight heading for the bottom.
  sounder([Move.sound, Move.sound, Move.bore, Move.thrash]),

  /// Cod, bass, snapper, and most of what you catch early. Scrappy and
  /// close-in — not weak, just busy.
  scrapper([Move.thrash, Move.thrash, Move.run, Move.bore]);

  const FightStyle(this.repertoire);

  /// The moves it draws from. Repeats bias the roll, so a runner mostly runs.
  final List<Move> repertoire;

  static FightStyle parse(String? code) => switch (code) {
        'runner' => FightStyle.runner,
        'jumper' => FightStyle.jumper,
        'sounder' => FightStyle.sounder,
        _ => FightStyle.scrapper,
      };
}

/// Everything the client needs to play one encounter out. The server derives
/// all of it; this file only obeys it.
class EncounterProfile {
  const EncounterProfile({
    required this.style,
    required this.staminaMs,
    required this.moves,
    required this.readMs,
    required this.tellMs,
    required this.holdMs,
    required this.gainPerPump,
    required this.lossOnMiss,
    required this.staminaPerRead,
    this.graceMisses = 0,
  });

  /// Built from the same `fight` blob the old profile reads. Every field has a
  /// defensible default, so an encounter rolled before the server knew about
  /// any of this still produces a playable fight rather than a crash.
  factory EncounterProfile.fromJson(Map<String, dynamic> json) {
    final moves = jsonInt(json['moves']);
    final safeMoves = moves > 0 ? moves : 4;
    return EncounterProfile(
      style: FightStyle.parse(json['style'] as String?),
      staminaMs: json['stamina_ms'] == null
          ? 12000
          : jsonDouble(json['stamina_ms']),
      moves: safeMoves,
      readMs: json['read_ms'] == null ? 900 : jsonDouble(json['read_ms']),
      tellMs: json['tell_ms'] == null ? 500 : jsonDouble(json['tell_ms']),
      holdMs: json['hold_ms'] == null ? 700 : jsonDouble(json['hold_ms']),
      gainPerPump:
          json['gain_per_pump'] == null ? 0.025 : jsonDouble(json['gain_per_pump']),
      lossOnMiss:
          json['loss_on_miss'] == null ? 0.08 : jsonDouble(json['loss_on_miss']),
      staminaPerRead: json['stamina_per_read'] == null
          ? 1 / math.max(1, safeMoves - 1)
          : jsonDouble(json['stamina_per_read']),
      graceMisses: json['grace_misses'] == null ? 1 : jsonInt(json['grace_misses']),
    );
  }

  /// Whether the server actually described a reading contest, as opposed to us
  /// having filled in every default. The panel uses this to decide which fight
  /// to play, so a stale encounter never lands in a half-configured one.
  static bool describedIn(Map<String, dynamic> json) =>
      json['style'] != null && json['moves'] != null;

  final FightStyle style;

  /// How much fight is in the animal, as a budget the player spends down by
  /// reading it correctly. Reaching zero is landing it.
  final double staminaMs;

  /// How many hazards it throws across the whole fight.
  final int moves;

  /// How long you have to answer once a hazard commits. THIS is the difficulty
  /// dial and THIS is what a better rod buys — everything else about a rod is
  /// decoration next to it.
  final double readMs;

  /// How long the tell runs before the hazard commits. A read window plus a
  /// tell is the total reaction time; the tell is the part you can see coming.
  final double tellMs;

  /// How long the hazard itself lasts once answered correctly.
  final double holdMs;

  /// Fraction of the fish's total fight that a second on the pump takes out of
  /// it, while it is merely working. Deliberately small: pumping is how you
  /// collect a fish you have already out-read, not a way to win without
  /// reading at all. An earlier cut let a player who misread every single tell
  /// still land it by waiting, which made the whole mechanic decorative.
  final double gainPerPump;

  /// Fraction of its fight a wrong answer GIVES BACK. A misread does not just
  /// fail to progress — it lets the animal recover.
  final double lossOnMiss;

  /// Fraction of its fight a correct answer takes out of it. Reading it is what
  /// beats it; winding is only how you collect.
  final double staminaPerRead;

  /// Wrong answers survivable before the hook pulls. Zero means the first
  /// mistake is the last one.
  final int graceMisses;
}

/// How it ended.
enum EncounterEnd { none, landed, threwTheHook, brokeOff, ranOut }

/// One hazard on the timeline.
class Hazard {
  Hazard(this.move, this.at);

  final Move move;

  /// When the tell starts, in ms from the hook being set.
  final double at;

  bool answered = false;
  bool correct = false;
}

/// The simulation. No Flutter, so the balance can be played against in a test
/// rather than only by hand — the same reason the old one was split out.
class EncounterSim {
  EncounterSim(this.profile, {math.Random? random})
      : _rng = random ?? math.Random() {
    hazards = _schedule();
  }

  final EncounterProfile profile;
  final math.Random _rng;

  late final List<Hazard> hazards;

  double elapsedMs = 0;

  /// How much fight it has left, counting down from the profile's budget. This
  /// is the ONLY resource in the encounter — there is deliberately no second
  /// track for distance, because two tracks meant two ways to win and one of
  /// them did not involve reading the fish at all.
  late double stamina = profile.staminaMs;

  /// 0..1 — how close it is to the boat, which is simply how beaten it is.
  double get progress =>
      profile.staminaMs <= 0 ? 1 : (1 - stamina / profile.staminaMs).clamp(0.0, 1.0);

  int misses = 0;
  int reads = 0;
  EncounterEnd end = EncounterEnd.none;

  /// The hazard currently on the table, if any.
  Hazard? _active;

  /// Set while a correct answer is being held out.
  double _holdUntil = -1;

  /// Whether the mistake that cost the fish left the line slack or loaded.
  bool _slackAtFailure = false;

  bool get isOver => end != EncounterEnd.none;

  /// What the fish is doing right now.
  Move get move => _active?.move ?? Move.work;

  /// Whether the current hazard is still only a tell, i.e. it has not committed
  /// yet and you are being given the chance to see it coming.
  bool get telling =>
      _active != null && elapsedMs < _active!.at + profile.tellMs;

  /// Whether a hazard is live and unanswered — the moment that matters.
  bool get awaitingAnswer =>
      _active != null && !_active!.answered && !telling;

  /// 0..1 — how much of the read window has burned. Drives the on-screen timer.
  double get readPressure {
    final h = _active;
    if (h == null || h.answered || telling) return 0;
    final since = elapsedMs - (h.at + profile.tellMs);
    return (since / profile.readMs).clamp(0.0, 1.0);
  }

  /// The share of hazards read correctly. This is what the server converts
  /// into a bonus, and it replaces the old "time spent inside the band".
  double get score => reads + misses == 0 ? 1 : reads / (reads + misses);

  /// Hazards spread across the fight with enough air between them to be
  /// individually readable. A wall of tells is noise, not difficulty.
  List<Hazard> _schedule() {
    final out = <Hazard>[];
    if (profile.moves <= 0) return out;
    final span = profile.staminaMs;
    final gap = span / (profile.moves + 1);
    final repertoire = profile.style.repertoire;

    // Two tells at once is noise rather than difficulty, so a hazard can never
    // start until the previous one's tell AND read window have fully run out.
    // Jitter is allowed to move a hazard later, never on top of its neighbour.
    final minGap = profile.tellMs + profile.readMs + profile.holdMs + 250;
    var previous = 0.0;
    for (var i = 0; i < profile.moves; i++) {
      final slot = gap * (i + 1);
      final jitter = (_rng.nextDouble() - 0.5) * gap * 0.5;
      final at = math.max(
        math.max(600.0, previous + minGap),
        slot + jitter,
      );
      out.add(Hazard(repertoire[_rng.nextInt(repertoire.length)], at));
      previous = at;
    }
    return out;
  }

  /// Advance the fight. [holding] is the counter the player currently has
  /// selected; [Counter.pump] is the resting choice.
  void step(double dtMs, {required Counter holding}) {
    if (isOver) return;
    elapsedMs += dtMs;

    // Bring the next hazard on when its tell is due.
    if (_active == null) {
      for (final h in hazards) {
        if (!h.answered && elapsedMs >= h.at) {
          _active = h;
          break;
        }
      }
    }

    final active = _active;
    if (active != null && !active.answered) {
      if (!telling) {
        // The window is open. An answer counts the moment it is selected.
        if (holding == active.move.answer) {
          _answer(active, holding, correct: true);
        } else if (readPressure >= 1.0) {
          // Time ran out, which is the same as being wrong.
          _answer(active, holding, correct: false);
        }
      }
    } else if (active == null || active.answered) {
      // Nothing to react to. Pumping is the only thing that gains ground, and
      // only once any held counter has run its course.
      if (elapsedMs >= _holdUntil && holding == Counter.pump) {
        stamina -=
            profile.gainPerPump * profile.staminaMs * (dtMs / 1000.0);
      }
      if (elapsedMs >= _holdUntil) _active = null;
    }

    stamina = stamina.clamp(0.0, profile.staminaMs);

    if (stamina <= 0) {
      end = EncounterEnd.landed;
    } else if (misses > profile.graceMisses) {
      // How you lost it follows from what YOU did, not from what would have
      // worked. Slack in the line throws the hook; too much of it parts the
      // leader. Both are losses, but they are different mistakes and the
      // player should be told which one they made.
      end = _slackAtFailure
          ? EncounterEnd.threwTheHook
          : EncounterEnd.brokeOff;
    } else if (elapsedMs > profile.staminaMs * 3) {
      end = EncounterEnd.ranOut;
    }
  }

  void _answer(Hazard h, Counter played, {required bool correct}) {
    h
      ..answered = true
      ..correct = correct;
    _holdUntil = elapsedMs + profile.holdMs;
    if (correct) {
      reads++;
      stamina -= profile.staminaPerRead * profile.staminaMs;
    } else {
      misses++;
      stamina += profile.lossOnMiss * profile.staminaMs;
      // Giving line or bowing puts slack in it; pumping or levering keeps it
      // loaded. That is the difference between the hook falling out and the
      // leader letting go.
      _slackAtFailure =
          played == Counter.giveLine || played == Counter.bow;
    }
  }
}
