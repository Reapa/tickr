import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/sound.dart';
import '../../../core/theme.dart';
import '../domain/fight_sim.dart';
import '../domain/fishery.dart';
import 'biome.dart';
import 'fight_scene.dart';
import 'sea.dart';

/// The fight.
///
/// Three beats, and each one is a different kind of attention:
///
///   WAIT   a float on the water for a variable delay, so you cannot pre-empt
///          it. It nods on a nibble before anything commits.
///   BITE   a reaction window: tap to set the hook, or it spits it
///   FIGHT  a duty cycle. Winding builds tension and brings the fish in; easing
///          off bleeds tension but makes no progress. The line snaps at the top
///          of the gauge and the fish has a finite stamina, so the whole game is
///          finding how hard you can lean on it without losing it.
///
/// This takes the whole screen rather than sitting in a card, because it is not
/// a widget on the fishery page — it is the game the fishery page is a lobby
/// for. Every constant driving it comes from the server in [FightProfile]. The
/// client animates; it does not decide. What it reports back is the outcome and
/// a `score` — the fraction of the fight spent inside the tension band — which
/// the server converts into a clamped bonus.
class FightPanel extends StatefulWidget {
  const FightPanel({
    super.key,
    required this.fight,
    required this.onFinished,
    this.spotName = '',
    this.spotCode,
  });

  final FightProfile fight;
  final String spotName;

  /// Which water this is. Decides the biome the scene is drawn in.
  final String? spotCode;

  /// (landed, score 0..1). Never fires before the fight could physically have
  /// been played — the server rejects resolves that arrive too early.
  final void Function(bool landed, double score) onFinished;

  @override
  State<FightPanel> createState() => _FightPanelState();
}

enum _Phase { waiting, bite, fighting, over }

class _FightPanelState extends State<FightPanel>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  /// The rules live in [FightSim] so they can be played against in a test
  /// rather than only by hand. This class owns input and pixels.
  late final FightSim _sim = FightSim(widget.fight);

  final FightFx _fx = FightFx();
  final math.Random _rng = math.Random();

  _Phase _phase = _Phase.waiting;
  double _elapsed = 0; // ms since the cast landed
  double _last = 0;
  double _fightStart = 0;
  double _biteAt = 0;

  bool _holding = false;
  double _lastReelSfx = 0;
  bool _wasSurging = false;
  bool _wasSnagging = false;
  bool _wasDiving = false;

  /// Camera kick. Decays on its own; surges keep topping it up.
  double _shakeMag = 0;
  Offset _shake = Offset.zero;

  /// 0..1 — the landing leap, played out after the sim is already over.
  double _breach = 0;
  bool _breachSplashed = false;

  /// When the float nods without anything committing. Purely theatre, but it is
  /// the theatre that makes the real bite land.
  late final List<double> _nibbles = _f.biteMs < 1400
      ? const []
      : [_f.biteMs * 0.40, if (_f.biteMs > 2600) _f.biteMs * 0.72];
  final Set<int> _nibbled = {};

  bool _landed = false;
  String _outcome = '';
  String _outcomeDetail = '';

  Size _size = Size.zero;

  FightProfile get _f => widget.fight;
  double get _tension => _sim.tension;
  double get _progress => _sim.progress;

  /// How far past the top of the band the line is, 0..1. Drives the colour
  /// grade, the chop and the warning bloom. Measured against the sim's LIVE
  /// ceiling, not the profile's, so a leader wearing through on ice makes the
  /// water angry earlier as the fight goes on.
  double get _strain => _sim.bandHigh >= 1
      ? 0
      : ((_tension - _sim.bandHigh) / (1 - _sim.bandHigh)).clamp(0.0, 1.0);

  /// A resolve sent sooner than this is rejected server-side as a forgery, so
  /// short losses (a missed hook) are held back to land on the normal path
  /// rather than tripping the anti-cheat clock.
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
    final dt = (now - _last).clamp(0.0, 50.0); // a tab-out must not snap the line
    _last = now;
    _elapsed = now;

    switch (_phase) {
      case _Phase.waiting:
        _stepNibbles();
        if (_elapsed >= _f.biteMs) {
          _biteAt = _elapsed;
          _phase = _Phase.bite;
          Sfx.splashBig();
          _fx.splash(_fx.entry, power: 0.7);
          _shakeMag += 5;
        }
      case _Phase.bite:
        if (_elapsed - _biteAt > _f.hookWindowMs) {
          _finish(false, 'It spat the hook', 'you were too slow on the strike');
        }
      case _Phase.fighting:
        _stepFight(dt);
      case _Phase.over:
        _stepAftermath(dt);
    }

    _stepScene(dt);
    if (mounted) setState(() {});
  }

  void _stepNibbles() {
    for (var i = 0; i < _nibbles.length; i++) {
      if (_elapsed >= _nibbles[i] && _nibbled.add(i)) {
        Sfx.tick();
        _fx.ring(_fx.entry);
      }
    }
  }

  void _stepFight(double dtMs) {
    if (_holding && _elapsed - _lastReelSfx > 380) {
      _lastReelSfx = _elapsed;
      Sfx.reel();
    }

    _sim.step(dtMs, holding: _holding);

    // A run starting is the moment that has to be legible, so it gets the
    // drag screaming and a kick in the camera as well as the colour change.
    if (_sim.surging && !_wasSurging) {
      Sfx.drag();
      _shakeMag += 7;
      _fx.splash(_fx.entry, power: 0.5);
    }
    _wasSurging = _sim.surging;

    // The two hazards ask for opposite things, so each needs its own
    // unmistakable announcement or they are just random deaths.
    if (_sim.snagging && !_wasSnagging) {
      Sfx.nope();
      _shakeMag += 4;
    }
    _wasSnagging = _sim.snagging;
    if (_sim.diving && !_wasDiving) {
      Sfx.drag();
      _shakeMag += 5;
    }
    _wasDiving = _sim.diving;

    switch (_sim.end) {
      case FightEnd.snapped:
        _finish(false, 'The line snapped', 'you leaned on it too hard');
      case FightEnd.landed:
        _finish(true, 'Landed!', 'bringing it aboard');
      case FightEnd.ranOut:
        _finish(false, 'It broke you off', 'it had more left than you did');
      case FightEnd.snagged:
        _finish(false, 'It reached the structure',
            'slack line let it get where it wanted');
      case FightEnd.none:
        break;
    }
  }

  void _stepAftermath(double dtMs) {
    if (!_landed) return;
    _breach = math.min(1, _breach + dtMs / 620);
    if (_breach >= 0.5 && !_breachSplashed) {
      _breachSplashed = true;
      Sfx.splashBig();
      _fx.splash(_fx.entry, power: 1.7);
      _shakeMag += 9;
    }
  }

  /// Particles, camera and the reel — everything that keeps moving whether or
  /// not the simulation is still running.
  void _stepScene(double dtMs) {
    final target = _sim.surgeIntensity * 3.4 + _strain * 1.6;
    _shakeMag += (target - _shakeMag) * math.min(1, dtMs / 90);
    _shakeMag = math.max(0, _shakeMag - dtMs * 0.012);
    _shake = _shakeMag < 0.05
        ? Offset.zero
        : Offset((_rng.nextDouble() - 0.5), (_rng.nextDouble() - 0.5)) *
            _shakeMag *
            2;

    // The reel turns in when you wind and gives line back when it runs — which
    // is the difference between winning ground and merely holding on.
    final reelRate = _phase != _Phase.fighting
        ? 0.0
        : _sim.surging
            ? -11.0 * _sim.surgeIntensity
            : _holding
                ? 8.5
                : 0.0;
    _fx.step(dtMs, surfaceY: _fx.surfaceY, reelRate: reelRate);

    if (_phase == _Phase.fighting) {
      _fx.trickleBubbles(_fx.fishAt, _sim.surgeIntensity);
      if (_tension > 0.2) _fx.trickleRing(_fx.entry);
    }
  }

  void _hook() {
    if (_phase != _Phase.bite) return;
    setState(() {
      _phase = _Phase.fighting;
      _fightStart = _elapsed;
      _sim.setHook();
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
    } else if (_sim.end == FightEnd.snapped) {
      Sfx.snap();
      _shakeMag += 14;
      _fx.splash(_fx.entry, power: 0.6);
    } else {
      Sfx.nope();
    }

    final score = _sim.score;
    final wait = math.max(0.0, _minResolveMs - _elapsed);

    if (mounted) setState(() {});
    // A landed fish gets long enough for the leap to actually read; a loss is
    // let go of quickly, because nobody wants to sit and look at it.
    Future<void>.delayed(
      Duration(milliseconds: (wait + (landed ? 1150 : 760)).round()),
      () {
        if (mounted) widget.onFinished(landed, score);
      },
    );
  }

  late final Biome _biome = Biome.of(widget.spotCode);

  /// This water at rest, this water under load, or the water that just beat
  /// you. Each spot brings its own two ends for that lerp.
  SeaPalette get _palette {
    if (_phase == _Phase.over && !_landed) {
      return SeaPalette.lerp(_biome.palette, SeaPalette.lost, 0.85);
    }
    return SeaPalette.lerp(_biome.palette, _biome.strained, _strain);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) {
            if (_phase == _Phase.bite) {
              _hook();
            } else if (_phase == _Phase.fighting) {
              setState(() => _holding = true);
            }
          },
          onPointerUp: (_) {
            if (_phase == _Phase.fighting) setState(() => _holding = false);
          },
          onPointerCancel: (_) {
            if (_phase == _Phase.fighting) setState(() => _holding = false);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  size: _size,
                  painter: FightScene(
                    t: _elapsed / 1000.0,
                    biome: _biome,
                    palette: _palette,
                    tension: _tension,
                    progress: _progress,
                    surge: _sim.surgeIntensity,
                    strain: _strain,
                    fishScale: _f.shadowScale,
                    hooked: _phase == _Phase.fighting,
                    reeling: _holding,
                    bobber: _phase == _Phase.waiting || _phase == _Phase.bite,
                    bobberDip: _bobberDip,
                    breach: _breach,
                    snapped: _sim.end == FightEnd.snapped,
                    fx: _fx,
                    shake: _shake,
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
                  child: Stack(
                    children: [
                      Align(alignment: Alignment.topCenter, child: _topHud()),
                      Center(child: _centrePrompt()),
                      Align(
                          alignment: Alignment.bottomCenter,
                          child: _bottomHud()),
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

  double get _bobberDip {
    if (_phase == _Phase.bite) return 1;
    for (final n in _nibbles) {
      if (_elapsed >= n && _elapsed < n + 280) {
        return math.sin((_elapsed - n) / 280 * math.pi) * 0.6;
      }
    }
    return 0;
  }

  // --------------------------------------------------------------------------
  // HUD
  // --------------------------------------------------------------------------

  Widget _topHud() {
    final fighting = _phase == _Phase.fighting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
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
            Text(
              _phase == _Phase.waiting
                  ? _f.shadowLabel.toUpperCase()
                  : fighting
                      ? (_holding ? 'WINDING' : 'GIVING LINE')
                      : '',
              style: _label(
                alpha: 0.7,
                color: fighting && _holding ? AppTheme.gold : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        AnimatedOpacity(
          opacity: fighting || _phase == _Phase.over ? 1 : 0.32,
          duration: const Duration(milliseconds: 200),
          child: _TensionGauge(
            tension: _tension,
            bandLow: _f.bandLow,
            bandHigh: _sim.bandHigh,
            strain: _strain,
          ),
        ),
        // How close the fish is to reaching whatever it is heading for. Only
        // on screen while that is actually a thing that is happening.
        if (_sim.snagging || _sim.snagDanger > 0) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Text('MAKING FOR STRUCTURE', style: _label(alpha: 0.85,
                  color: AppTheme.gold)),
              const Spacer(),
              if (_tension < _f.bandLow)
                Text('LINE IS SLACK', style: _label(alpha: 1, color: AppTheme.down)),
            ],
          ),
          const SizedBox(height: 4),
          _Meter(
            value: _sim.snagDanger,
            color: _sim.snagDanger > 0.6 ? AppTheme.down : AppTheme.gold,
            height: 5,
          ),
        ],
      ],
    );
  }

  Widget _bottomHud() {
    if (_phase == _Phase.waiting) {
      return Text('KEEP AN EYE ON THE FLOAT',
          style: _label(alpha: 0.42), textAlign: TextAlign.center);
    }
    final stamina = _phase == _Phase.fighting
        ? (1 - ((_elapsed - _fightStart) / _f.staminaMs)).clamp(0.0, 1.0)
        : 0.0;
    // Distance reads better than a percentage: 12 m off the boat is a picture,
    // 71% is a number.
    final metres = (40 * (1 - _progress)).clamp(0.0, 40.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('TO THE BOAT', style: _label(alpha: 0.6)),
            const Spacer(),
            Text(
              metres < 1 ? 'ALONGSIDE' : '${metres.toStringAsFixed(0)} m',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
                shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        _Meter(
          value: _progress,
          color: AppTheme.gold,
          height: 7,
        ),
        const SizedBox(height: 9),
        Row(
          children: [
            Text('IT IS TIRING', style: _label(alpha: 0.45)),
            const Spacer(),
            if (_phase == _Phase.fighting)
              Text(
                stamina < 0.25 ? 'ALMOST BEATEN' : '',
                style: _label(alpha: 0.75, color: AppTheme.up),
              ),
          ],
        ),
        const SizedBox(height: 4),
        _Meter(
          value: 1 - stamina,
          color: Colors.white.withValues(alpha: 0.5),
          height: 3,
        ),
      ],
    );
  }

  Widget _centrePrompt() {
    switch (_phase) {
      case _Phase.waiting:
        return const SizedBox.shrink();
      case _Phase.bite:
        // The whole reaction window, and nothing else on screen.
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.55, end: 1.0),
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOutBack,
          builder: (context, v, child) =>
              Transform.scale(scale: v, child: child),
          child: const _Prompt(
            title: 'BITE!',
            subtitle: 'TAP TO SET THE HOOK',
            accent: AppTheme.gold,
            big: true,
          ),
        );
      case _Phase.fighting:
        // The hint gets out of the way once the fight is actually happening —
        // after that the rod and the water are the instruments.
        final fresh = _elapsed - _fightStart < 1600;
        // Order matters: a snag is the only one of the three that kills you for
        // doing the thing the other two want, so it has to win the screen.
        if (_sim.snagging) {
          return const _Prompt(
            title: "IT'S GOING FOR THE STRUCTURE",
            subtitle: 'KEEP THE LINE TIGHT — TURN ITS HEAD',
            accent: AppTheme.gold,
            big: true,
          );
        }
        if (_sim.surging) {
          return const _Prompt(
            title: "IT'S RUNNING",
            subtitle: 'EASE OFF — LET IT TAKE LINE',
            accent: AppTheme.down,
            big: true,
          );
        }
        if (_sim.diving) {
          return const _Prompt(
            title: "IT'S SOUNDING",
            subtitle: 'WIND THROUGH IT OR LOSE THE GROUND',
            accent: AppTheme.accent,
            big: true,
          );
        }
        if (!fresh) return const SizedBox.shrink();
        return _Prompt(
          title: '',
          subtitle: 'HOLD ANYWHERE TO WIND  ·  RELEASE TO EASE OFF',
          dim: true,
        );
      case _Phase.over:
        return _Prompt(
          title: _outcome,
          subtitle: _outcomeDetail,
          accent: _landed ? AppTheme.up : AppTheme.down,
          big: true,
        );
    }
  }

  TextStyle _label({double alpha = 0.6, Color? color}) => TextStyle(
        color: color ?? Colors.white.withValues(alpha: alpha),
        fontSize: 9.5,
        letterSpacing: 1.7,
        fontWeight: FontWeight.w900,
        shadows: const [Shadow(blurRadius: 8, color: Colors.black87)],
      );
}

class _Prompt extends StatelessWidget {
  const _Prompt({
    required this.title,
    required this.subtitle,
    this.accent,
    this.dim = false,
    this.big = false,
  });

  final String title;
  final String subtitle;
  final Color? accent;
  final bool dim;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title.isNotEmpty)
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: accent ?? Colors.white.withValues(alpha: dim ? 0.62 : 0.95),
              fontSize: big ? 30 : 17,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w900,
              shadows: const [
                Shadow(blurRadius: 18, color: Colors.black),
                Shadow(blurRadius: 6, color: Colors.black87),
              ],
            ),
          ),
        if (subtitle.isNotEmpty) ...[
          if (title.isNotEmpty) const SizedBox(height: 7),
          Text(
            subtitle.toUpperCase(),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.66),
              fontSize: 10.5,
              letterSpacing: 1.6,
              fontWeight: FontWeight.w800,
              shadows: const [Shadow(blurRadius: 10, color: Colors.black87)],
            ),
          ),
        ],
      ],
    );
  }
}

/// A thin progress meter with a dark track, used for distance and stamina.
class _Meter extends StatelessWidget {
  const _Meter({required this.value, required this.color, required this.height});

  final double value;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: LinearProgressIndicator(
          value: value.clamp(0.0, 1.0),
          minHeight: height,
          backgroundColor: Colors.black.withValues(alpha: 0.45),
          color: color,
        ),
      );
}

/// Line tension, drawn as an instrument rather than a progress bar: a scale
/// with ticks, the working band picked out in green, the red shoulder hatched,
/// and a needle you can read at a glance while looking at the water.
class _TensionGauge extends StatelessWidget {
  const _TensionGauge({
    required this.tension,
    required this.bandLow,
    required this.bandHigh,
    required this.strain,
  });

  final double tension;
  final double bandLow;
  final double bandHigh;
  final double strain;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('LINE TENSION',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 9,
                    letterSpacing: 1.6,
                    fontWeight: FontWeight.w900,
                    shadows: const [
                      Shadow(blurRadius: 8, color: Colors.black87)
                    ])),
            const Spacer(),
            if (strain > 0)
              Text(strain > 0.6 ? 'ABOUT TO GO' : 'TOO TIGHT',
                  style: TextStyle(
                      color: AppTheme.down,
                      fontSize: 9,
                      letterSpacing: 1.6,
                      fontWeight: FontWeight.w900,
                      shadows: const [
                        Shadow(blurRadius: 8, color: Colors.black87)
                      ])),
          ],
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: 18,
          child: CustomPaint(
            size: Size.infinite,
            painter: _GaugePainter(
              tension: tension,
              bandLow: bandLow,
              bandHigh: bandHigh,
              strain: strain,
            ),
          ),
        ),
      ],
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.tension,
    required this.bandLow,
    required this.bandHigh,
    required this.strain,
  });

  final double tension;
  final double bandLow;
  final double bandHigh;
  final double strain;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(4));
    canvas.drawRRect(r, Paint()..color = Colors.black.withValues(alpha: 0.5));
    canvas.save();
    canvas.clipRRect(r);

    // The working band.
    canvas.drawRect(
      Rect.fromLTRB(size.width * bandLow, 0, size.width * bandHigh, size.height),
      Paint()..color = AppTheme.up.withValues(alpha: 0.18),
    );

    // Hatching over the shoulder, so "past the band" is a texture you notice
    // in peripheral vision rather than a shade of the same colour.
    final hatch = Paint()
      ..color = AppTheme.down.withValues(alpha: 0.30)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.save();
    canvas.clipRect(
        Rect.fromLTRB(size.width * bandHigh, 0, size.width, size.height));
    for (double x = size.width * bandHigh - size.height;
        x < size.width;
        x += 6) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), hatch);
    }
    canvas.restore();

    // The fill.
    final w = (size.width * tension).clamp(0.0, size.width);
    final fill = strain > 0
        ? AppTheme.down
        : tension < bandLow
            ? Colors.white.withValues(alpha: 0.55)
            : AppTheme.up;
    canvas.drawRect(
      Rect.fromLTRB(0, 3, w, size.height - 3),
      Paint()..color = fill.withValues(alpha: 0.85),
    );

    // Scale ticks.
    final tick = Paint()..color = Colors.white.withValues(alpha: 0.18);
    for (var i = 1; i < 10; i++) {
      final x = size.width * i / 10;
      canvas.drawRect(
          Rect.fromLTWH(x, size.height * 0.28, 1, size.height * 0.44), tick);
    }

    // Band edges, then the needle.
    final edge = Paint()..color = AppTheme.up.withValues(alpha: 0.8);
    canvas.drawRect(
        Rect.fromLTWH(size.width * bandLow - 0.5, 0, 1.4, size.height), edge);
    canvas.drawRect(
        Rect.fromLTWH(size.width * bandHigh - 0.5, 0, 1.4, size.height), edge);

    canvas.drawRect(
      Rect.fromLTWH(w - 1.2, -1, 2.4, size.height + 2),
      Paint()
        ..color = Colors.white
        ..maskFilter = strain > 0
            ? const MaskFilter.blur(BlurStyle.solid, 3)
            : null,
    );

    canvas.restore();
    canvas.drawRRect(
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.tension != tension || old.strain != strain;
}
