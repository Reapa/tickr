import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/sound.dart';
import '../../../core/theme.dart';
import '../domain/encounter_sim.dart';
import '../domain/fishery.dart';
import 'biome.dart';
import 'fight_scene.dart';
import 'fish_shapes.dart';
import 'sea.dart';

/// The reading contest, on screen.
///
/// Three beats, as before — a float, a bite, and then the fight — but the fight
/// is no longer a bar to park a number in. The fish does something, you have a
/// moment to recognise it, and you answer. The read window is drawn as a
/// closing ring around the tell, because the pressure IS the difficulty and
/// hiding it in a subtle colour change would make the whole thing feel unfair.
class EncounterPanel extends StatefulWidget {
  const EncounterPanel({
    super.key,
    required this.fight,
    required this.profile,
    required this.onFinished,
    this.spotName = '',
    this.spotCode,
  });

  final FightProfile fight;
  final EncounterProfile profile;
  final String spotName;
  final String? spotCode;

  /// (landed, score 0..1) — the same contract the old panel had, so the server
  /// side of resolving a catch does not change at all.
  final void Function(bool landed, double score) onFinished;

  @override
  State<EncounterPanel> createState() => _EncounterPanelState();
}

enum _Phase { waiting, bite, fighting, over }

class _EncounterPanelState extends State<EncounterPanel>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final EncounterSim _sim = EncounterSim(widget.profile);
  late final Biome _biome = Biome.of(widget.spotCode);

  /// The species is deliberately withheld until it is in the boat, so the shape
  /// is inferred from its size and how it fights. That is not a workaround —
  /// it IS the shadow: a huge thing that runs is a shark, a thing that jumps
  /// has a bill, and working that out mid-fight is the whole idea.
  late final BodyPlan _plan =
      BodyPlan.fromShadow(_f.shadow, widget.profile.style.name);

  final FightFx _fx = FightFx();
  final math.Random _rng = math.Random();

  _Phase _phase = _Phase.waiting;
  double _elapsed = 0;
  double _last = 0;
  double _biteAt = 0;

  /// Whether the angler is on the rod. PUMP is the one counter that is a held
  /// action; the other three are answers, and an answer is a thing you do once.
  bool _pumping = false;

  /// The counter last played, and when — purely so the button can flash. It is
  /// not state the simulation reads, which is the entire fix for the selection
  /// snapping out from under the player mid-run.
  Counter? _played;
  double _playedAt = -9999;

  Move? _announced;
  int _lastReads = 0;
  int _lastMisses = 0;

  /// When the current move COMMITTED — not when its tell began. The tell is a
  /// wind-up; the choreography belongs to the move itself.
  double _moveAt = -9999;
  Move _sceneMove = Move.work;

  /// How long a move takes to LOOK like it happened, which is not how long the
  /// simulation spends on it. A jump is a jump whether you answered it in 200ms
  /// or let the window run out — tying the arc to the sim meant a fast answer
  /// cut the animation off part-way and the fish snapped back across the frame.
  static const double _moveVisualMs = 950;

  /// 0..1 through whatever the fish is doing, for the scene to animate against.
  double get _actionPhase {
    if (_sceneMove == Move.work) return 0;
    return ((_elapsed - _moveAt) / _moveVisualMs).clamp(0.0, 1.0);
  }

  double _shakeMag = 0;
  Offset _shake = Offset.zero;
  double _breach = 0;
  bool _breachSplashed = false;

  bool _landed = false;
  String _outcome = '';
  String _outcomeDetail = '';

  FightProfile get _f => widget.fight;
  double get _minResolveMs => _f.biteMs + 1000;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration d) {
    final now = d.inMicroseconds / 1000.0;
    final dt = (now - _last).clamp(0.0, 50.0);
    _last = now;
    _elapsed = now;

    switch (_phase) {
      case _Phase.waiting:
        if (_elapsed >= _f.biteMs) {
          _biteAt = _elapsed;
          _phase = _Phase.bite;
          Sfx.splashBig();
          _fx.splash(_fx.entry, power: 0.7);
          _shakeMag += 5;
        }
      case _Phase.bite:
        if (_elapsed - _biteAt > _f.hookWindowMs) {
          _finish(false, 'It spat the hook', 'too slow on the strike');
        }
      case _Phase.fighting:
        _stepFight(dt);
      case _Phase.over:
        if (_landed) {
          _breach = math.min(1, _breach + dt / 620);
          if (_breach >= 0.5 && !_breachSplashed) {
            _breachSplashed = true;
            Sfx.splashBig();
            _fx.splash(_fx.entry, power: 1.7);
            _shakeMag += 9;
          }
        }
    }

    _stepScene(dt);
    if (mounted) setState(() {});
  }

  void _stepFight(double dtMs) {
    final wasMove = _sim.move;
    _sim.step(dtMs, pumping: _pumping);

    // Announce a hazard once, the instant it commits — this is the beat the
    // whole mechanic hangs on.
    if (_sim.awaitingAnswer && _announced != _sim.move) {
      _announced = _sim.move;
      _shakeMag += 5;
      switch (_sim.move) {
        case Move.run:
          Sfx.drag();
        case Move.jump:
          Sfx.splashBig();
          _fx.splash(_fx.entry, power: 1.1);
        case Move.sound:
        case Move.bore:
          Sfx.drag();
        default:
          Sfx.tick();
      }
    }
    if (!_sim.awaitingAnswer && wasMove == Move.work) _announced = null;

    // The scene's move starts the instant the fish commits and then runs its
    // own clock. A new hazard can interrupt it; the simulation finishing early
    // cannot, because a half-played jump ending abruptly is precisely the
    // teleport this is here to prevent.
    final live = !_sim.telling ? _sim.move : Move.work;
    if (live != Move.work && live != _sceneMove) {
      _sceneMove = live;
      _moveAt = _elapsed;
    } else if (_sceneMove != Move.work &&
        _elapsed - _moveAt >= _moveVisualMs) {
      _sceneMove = Move.work;
    }

    // Feedback on the answer itself, right or wrong. Nothing here touches what
    // the player is holding — the answer has already been played.
    if (_sim.reads > _lastReads) {
      _lastReads = _sim.reads;
      Sfx.catchCommon();
      _announced = null;
    }
    if (_sim.misses > _lastMisses) {
      _lastMisses = _sim.misses;
      Sfx.nope();
      _shakeMag += 10;
      _announced = null;
    }

    switch (_sim.end) {
      case EncounterEnd.landed:
        _finish(true, 'Landed!', 'bringing it aboard');
      case EncounterEnd.threwTheHook:
        _finish(false, 'It threw the hook', 'you gave it slack');
      case EncounterEnd.brokeOff:
        _finish(false, 'The leader parted', 'you never gave it line');
      case EncounterEnd.ranOut:
        _finish(false, 'It beat you', 'it had more in it than you did');
      case EncounterEnd.none:
        break;
    }
  }

  void _stepScene(double dtMs) {
    _shakeMag = math.max(0, _shakeMag - dtMs * 0.014);
    _shake = _shakeMag < 0.05
        ? Offset.zero
        : Offset(_rng.nextDouble() - 0.5, _rng.nextDouble() - 0.5) *
            _shakeMag *
            2;
    _fx.step(dtMs, surfaceY: _fx.surfaceY, reelRate: _reelRate);
    if (_phase == _Phase.fighting) {
      _fx.trickleBubbles(_fx.fishAt, _sim.move == Move.run ? 1 : 0.3);
      _fx.trickleRing(_fx.entry);
    }
  }

  double get _reelRate => switch (_phase) {
        _Phase.fighting when _sim.move == Move.run => -12,
        _Phase.fighting when _pumping => 8.5,
        _ => 0.0,
      };

  /// Play a counter. Answers are one-shot; pumping is handled by the hold.
  void _play(Counter c) {
    if (_phase != _Phase.fighting) return;
    setState(() {
      _played = c;
      _playedAt = _elapsed;
    });
    if (c == Counter.pump) return;
    if (_sim.answer(c)) {
      _shakeMag += 3;
    } else {
      // Answering thin air is not punished — a fish that is not doing anything
      // cannot be got wrong — but it should still feel like nothing happened.
      Sfx.tick();
    }
  }

  void _hook() {
    if (_phase != _Phase.bite) return;
    setState(() {
      _phase = _Phase.fighting;

    });
    Sfx.splash();
    _fx.splash(_fx.entry, power: 0.9);
    _shakeMag += 6;
  }

  void _finish(bool landed, String outcome, String detail) {
    if (_phase == _Phase.over) return;
    _phase = _Phase.over;
    _landed = landed;
    _outcome = outcome;
    _outcomeDetail = detail;
    if (landed) {
      _fx.splash(_fx.entry, power: 1.2);
    } else {
      Sfx.snap();
      _shakeMag += 12;
    }

    final score = _sim.score;
    final wait = math.max(0.0, _minResolveMs - _elapsed);
    if (mounted) setState(() {});
    Future<void>.delayed(
      Duration(milliseconds: (wait + (landed ? 1150 : 800)).round()),
      () {
        if (mounted) widget.onFinished(landed, score);
      },
    );
  }

  // --------------------------------------------------------------------------
  // Scene mapping
  //
  // The scene still speaks the old language of tension and surges, so each move
  // is translated into it. Cheap, and it means a run already looks like a run
  // without the painter knowing anything about the new model.
  // --------------------------------------------------------------------------

  double get _sceneTension => switch (_sim.move) {
        Move.run => 0.88,
        Move.sound || Move.bore => 0.72,
        Move.jump || Move.thrash => 0.55,
        Move.work => _pumping ? 0.55 : 0.3,
      };

  double get _sceneSurge =>
      _sim.move == Move.run || _sim.move == Move.thrash ? 1 : 0;

  SeaPalette get _palette {
    if (_phase == _Phase.over && !_landed) {
      return SeaPalette.lerp(_biome.palette, SeaPalette.lost, 0.85);
    }
    // The water only turns angry while something is actually happening.
    return SeaPalette.lerp(
        _biome.palette, _biome.strained, _sim.awaitingAnswer ? 0.55 : 0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) {
            if (_phase == _Phase.bite) _hook();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  size: constraints.biggest,
                  painter: FightScene(
                    t: _elapsed / 1000.0,
                    biome: _biome,
                    palette: _palette,
                    tension: _sceneTension,
                    progress: _sim.progress,
                    surge: _sceneSurge,
                    strain: _sim.awaitingAnswer ? _sim.readPressure : 0,
                    fishScale: _f.shadowScale,
                    plan: _plan,
                    action:
                        _phase == _Phase.fighting ? _sceneMove : Move.work,
                    actionPhase: _actionPhase,
                    hooked: _phase == _Phase.fighting,
                    reeling: _pumping,
                    bobber: _phase == _Phase.waiting || _phase == _Phase.bite,
                    bobberDip: _phase == _Phase.bite ? 1 : 0,
                    // A jumping fish is genuinely out of the water, so it
                    // borrows the landing leap the scene already knows how to
                    // draw. This is the cheap version; the real one is a
                    // per-species animation and comes with the art pass.
                    breach: _phase == _Phase.over && _landed
                        ? _breach
                        : (_sim.move == Move.jump ? 0.7 : 0),
                    snapped: _phase == _Phase.over && !_landed,
                    fx: _fx,
                    shake: _shake,
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
                  child: Column(
                    children: [
                      _topHud(),
                      const Spacer(),
                      _centre(),
                      const Spacer(),
                      if (_phase == _Phase.fighting) _counters(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _topHud() {
    final p = widget.profile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.spotName.isEmpty
                    ? 'ON THE LINE'
                    : widget.spotName.toUpperCase(),
                style: _label(alpha: 0.5),
              ),
            ),
            if (_phase == _Phase.fighting)
              Text(
                'MISTAKES  ${_sim.misses}/${p.graceMisses}',
                style: _label(
                  alpha: 0.8,
                  color: _sim.misses >= p.graceMisses ? AppTheme.down : null,
                ),
              ),
          ],
        ),
        const SizedBox(height: 9),
        Text('HOW BEATEN IT IS', style: _label(alpha: 0.55)),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _sim.progress,
            minHeight: 7,
            backgroundColor: Colors.black.withValues(alpha: 0.45),
            color: AppTheme.gold,
          ),
        ),
      ],
    );
  }

  Widget _centre() {
    switch (_phase) {
      case _Phase.waiting:
        return Text('WATCH THE FLOAT',
            style: _label(alpha: 0.45), textAlign: TextAlign.center);
      case _Phase.bite:
        return _Big(title: 'BITE!', sub: 'TAP TO SET THE HOOK',
            accent: AppTheme.gold);
      case _Phase.fighting:
        if (_sim.telling) {
          return _Big(
            title: 'IT TENSES',
            sub: 'SOMETHING IS COMING',
            accent: AppTheme.accent,
          );
        }
        if (_sim.awaitingAnswer) {
          return _ReadPrompt(
            move: _sim.move,
            pressure: _sim.readPressure,
          );
        }
        return Text(
          _sim.reads == 0
              ? 'PUMP TO GAIN LINE'
              : 'IT IS WORKING — PUMP',
          style: _label(alpha: 0.5),
          textAlign: TextAlign.center,
        );
      case _Phase.over:
        return _Big(
          title: _outcome,
          sub: _outcomeDetail,
          accent: _landed ? AppTheme.up : AppTheme.down,
        );
    }
  }

  /// The four counters. Always all four, always in the same places — a button
  /// that moves or disappears cannot be learned, and learning them is the game.
  ///
  /// PUMP is held; the other three are tapped. That split is the whole reason
  /// letting the line loose felt glitchy before: an answer was a selection the
  /// panel then had to take away again.
  Widget _counters() {
    return Row(
      children: [
        for (final c in Counter.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: _CounterButton(
                counter: c,
                held: c == Counter.pump && _pumping,
                // A tapped answer flashes for a beat so the input is visibly
                // acknowledged even when the fish's reaction lags it.
                flash: _played == c && _elapsed - _playedAt < 260,
                onDown: () {
                  if (c == Counter.pump) setState(() => _pumping = true);
                  _play(c);
                },
                onUp: () {
                  if (c == Counter.pump) setState(() => _pumping = false);
                },
              ),
            ),
          ),
      ],
    );
  }

  TextStyle _label({double alpha = 0.6, Color? color}) => TextStyle(
        color: color ?? Colors.white.withValues(alpha: alpha),
        fontSize: 9.5,
        letterSpacing: 1.7,
        fontWeight: FontWeight.w900,
        shadows: const [Shadow(blurRadius: 8, color: Colors.black87)],
      );
}

class _Big extends StatelessWidget {
  const _Big({required this.title, required this.sub, required this.accent});

  final String title;
  final String sub;
  final Color accent;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title.toUpperCase(),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: accent,
                fontSize: 28,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w900,
                shadows: const [
                  Shadow(blurRadius: 18, color: Colors.black),
                  Shadow(blurRadius: 6, color: Colors.black87),
                ],
              )),
          const SizedBox(height: 7),
          Text(sub.toUpperCase(),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 10.5,
                letterSpacing: 1.6,
                fontWeight: FontWeight.w800,
                shadows: const [Shadow(blurRadius: 10, color: Colors.black87)],
              )),
        ],
      );
}

/// What the fish just did, and how long is left to answer it. The ring is the
/// read window draining; when it closes, the moment is gone.
class _ReadPrompt extends StatelessWidget {
  const _ReadPrompt({required this.move, required this.pressure});

  final Move move;
  final double pressure;

  @override
  Widget build(BuildContext context) {
    final urgent = pressure > 0.6;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 92,
          height: 92,
          child: CustomPaint(
            painter: _RingPainter(
              remaining: 1 - pressure,
              color: urgent ? AppTheme.down : AppTheme.gold,
            ),
            child: Center(
              child: Icon(
                switch (move) {
                  Move.run => Icons.fast_forward,
                  Move.jump => Icons.arrow_upward,
                  Move.thrash => Icons.sync_alt,
                  Move.sound => Icons.arrow_downward,
                  Move.bore => Icons.call_split,
                  Move.work => Icons.circle_outlined,
                },
                size: 34,
                color: urgent ? AppTheme.down : Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          move.tell,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: urgent ? AppTheme.down : Colors.white,
            fontSize: 20,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w900,
            shadows: const [Shadow(blurRadius: 16, color: Colors.black)],
          ),
        ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.remaining, required this.color});

  final double remaining;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(6, 6, size.width - 12, size.height - 12);
    canvas.drawArc(rect, 0, math.pi * 2, false,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * remaining.clamp(0.0, 1.0),
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 6,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.remaining != remaining || old.color != color;
}

class _CounterButton extends StatelessWidget {
  const _CounterButton({
    required this.counter,
    required this.held,
    required this.flash,
    required this.onDown,
    required this.onUp,
  });

  final Counter counter;

  /// Only PUMP is ever held.
  final bool held;

  /// A brief acknowledgement of a tap, independent of what the fish does next.
  final bool flash;
  final VoidCallback onDown;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context) {
    final colour = switch (counter) {
      Counter.pump => AppTheme.up,
      Counter.giveLine => AppTheme.accent,
      Counter.bow => AppTheme.gold,
      Counter.sidePressure => AppTheme.brand,
    };
    final lit = held || flash;
    return Listener(
      onPointerDown: (_) => onDown(),
      onPointerUp: (_) => onUp(),
      onPointerCancel: (_) => onUp(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: lit
              ? colour.withValues(alpha: 0.85)
              : Colors.black.withValues(alpha: 0.55),
          border: Border.all(
            color: lit ? colour : colour.withValues(alpha: 0.45),
            width: lit ? 2 : 1.2,
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: lit
              ? [BoxShadow(color: colour.withValues(alpha: 0.5), blurRadius: 14)]
              : null,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              switch (counter) {
                Counter.pump => Icons.keyboard_double_arrow_up,
                Counter.giveLine => Icons.linear_scale,
                Counter.bow => Icons.keyboard_double_arrow_down,
                Counter.sidePressure => Icons.swap_horiz,
              },
              size: 20,
              color: lit ? Colors.black : colour,
            ),
            const SizedBox(height: 3),
            Text(
              counter == Counter.pump ? 'HOLD TO PUMP' : counter.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: lit ? Colors.black : Colors.white,
                fontSize: 8.5,
                height: 1.1,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
