import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/sound.dart';
import '../../../core/theme.dart';
import '../domain/fight_sim.dart';
import '../domain/fishery.dart';

/// The fight — the thing there was previously nothing of.
///
/// Three beats, and each one is a different kind of attention:
///
///   WAIT   the float sits there for a variable delay, so you cannot pre-empt it
///   BITE   a reaction window: tap to set the hook, or it spits it
///   FIGHT  a duty cycle. Winding builds tension and brings the fish in; easing
///          off bleeds tension but makes no progress. The line snaps at the top
///          of the gauge and the fish has a finite stamina, so the whole game is
///          finding how hard you can lean on it without losing it.
///
/// Every constant driving this comes from the server in [FightProfile]. The
/// client animates; it does not decide. What it reports back is the outcome and
/// a `score` — the fraction of the fight spent inside the tension band — which
/// the server converts into a clamped bonus.
class FightPanel extends StatefulWidget {
  const FightPanel({
    super.key,
    required this.fight,
    required this.onFinished,
  });

  final FightProfile fight;

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

  _Phase _phase = _Phase.waiting;
  double _elapsed = 0; // ms since the cast landed
  double _last = 0;
  double _fightStart = 0;
  double _biteAt = 0;

  bool _holding = false;
  double _lastReelSfx = 0;

  bool _landed = false;
  String _outcome = '';

  FightProfile get _f => widget.fight;
  double get _tension => _sim.tension;
  double get _progress => _sim.progress;
  bool get _surging => _sim.surging;

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
        if (_elapsed >= _f.biteMs) {
          _biteAt = _elapsed;
          _phase = _Phase.bite;
          Sfx.splash();
        }
      case _Phase.bite:
        if (_elapsed - _biteAt > _f.hookWindowMs) {
          _finish(false, 'It spat the hook.');
        }
      case _Phase.fighting:
        _stepFight(dt);
      case _Phase.over:
        return;
    }
    if (mounted) setState(() {});
  }

  void _stepFight(double dtMs) {
    if (_holding && _elapsed - _lastReelSfx > 380) {
      _lastReelSfx = _elapsed;
      Sfx.reel();
    }

    _sim.step(dtMs, holding: _holding);

    switch (_sim.end) {
      case FightEnd.snapped:
        _finish(false, 'The line snapped.');
      case FightEnd.landed:
        _finish(true, 'Landed!');
      case FightEnd.ranOut:
        _finish(false, 'It ran you out and broke off.');
      case FightEnd.none:
        break;
    }
  }

  void _hook() {
    if (_phase != _Phase.bite) return;
    setState(() {
      _phase = _Phase.fighting;
      _fightStart = _elapsed;
      _sim.setHook();
    });
    Sfx.tick();
  }

  void _finish(bool landed, String outcome) {
    if (_phase == _Phase.over) return;
    _phase = _Phase.over;
    _ticker.stop();
    _landed = landed;
    _outcome = outcome;
    if (!landed) Sfx.nope();

    final score = _sim.score;
    final wait = math.max(0.0, _minResolveMs - _elapsed);

    if (mounted) setState(() {});
    Future<void>.delayed(
      Duration(milliseconds: (wait + 620).round()),
      () {
        if (mounted) widget.onFinished(landed, score);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapping = _tension > _f.bandHigh;
    return Listener(
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
      child: Container(
        height: 300,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: _phase == _Phase.over && !_landed
                ? const [Color(0xFF3A1520), Color(0xFF14060A)]
                : snapping
                    ? const [Color(0xFF5C2A0E), Color(0xFF1E0C04)]
                    : const [Color(0xFF0E3A5C), Color(0xFF03131F)],
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _FightPainter(
                  phase: _phase,
                  elapsed: _elapsed,
                  progress: _progress,
                  tension: _tension,
                  surging: _surging,
                  shadowScale: _f.shadowScale,
                  landed: _landed,
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              top: 14,
              child: _TensionGauge(
                tension: _tension,
                bandLow: _f.bandLow,
                bandHigh: _f.bandHigh,
                active: _phase == _Phase.fighting,
              ),
            ),
            Positioned.fill(child: Center(child: _centrePrompt())),
            if (_phase == _Phase.fighting || _phase == _Phase.over)
              Positioned(
                left: 16,
                right: 16,
                bottom: 14,
                child: _DistanceBar(
                  progress: _progress,
                  staminaLeft: _phase == _Phase.fighting
                      ? (1 - ((_elapsed - _fightStart) / _f.staminaMs))
                          .clamp(0.0, 1.0)
                          .toDouble()
                      : 0,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _centrePrompt() {
    switch (_phase) {
      case _Phase.waiting:
        return _Prompt(
          title: _f.shadowLabel.toUpperCase(),
          subtitle: 'is circling the bait…',
          dim: true,
        );
      case _Phase.bite:
        // The whole reaction window, and nothing else on screen.
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.6, end: 1.0),
          duration: const Duration(milliseconds: 140),
          builder: (context, v, child) =>
              Transform.scale(scale: v, child: child),
          child: const _Prompt(
            title: 'BITE!',
            subtitle: 'TAP TO SET THE HOOK',
            accent: AppTheme.gold,
          ),
        );
      case _Phase.fighting:
        return _Prompt(
          title: _holding ? 'REELING' : 'GIVE IT LINE',
          subtitle: _surging
              ? "IT'S RUNNING — EASE OFF"
              : 'hold anywhere to wind  ·  release to bleed tension',
          accent: _surging ? AppTheme.down : null,
          dim: !_surging,
        );
      case _Phase.over:
        return _Prompt(
          title: _outcome,
          subtitle: _landed ? 'bringing it aboard…' : '',
          accent: _landed ? AppTheme.up : AppTheme.down,
        );
    }
  }
}

class _Prompt extends StatelessWidget {
  const _Prompt({
    required this.title,
    required this.subtitle,
    this.accent,
    this.dim = false,
  });

  final String title;
  final String subtitle;
  final Color? accent;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: accent ?? Colors.white.withValues(alpha: dim ? 0.62 : 0.95),
            fontSize: accent != null && !dim ? 26 : 17,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w900,
            shadows: const [Shadow(blurRadius: 12, color: Colors.black54)],
          ),
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 11,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

/// Line tension. The band is where a clean fight lives; the red shoulder above
/// it is survivable but scores nothing, and the top of the bar is a snap.
class _TensionGauge extends StatelessWidget {
  const _TensionGauge({
    required this.tension,
    required this.bandLow,
    required this.bandHigh,
    required this.active,
  });

  final double tension;
  final double bandLow;
  final double bandHigh;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: active ? 1 : 0.35,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('LINE TENSION',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 9,
                      letterSpacing: 1.6,
                      fontWeight: FontWeight.w900)),
              const Spacer(),
              Text(tension > bandHigh ? 'TOO TIGHT' : '',
                  style: const TextStyle(
                      color: AppTheme.down,
                      fontSize: 9,
                      letterSpacing: 1.6,
                      fontWeight: FontWeight.w900)),
            ],
          ),
          const SizedBox(height: 5),
          LayoutBuilder(
            builder: (context, c) => SizedBox(
              height: 14,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  Positioned(
                    left: c.maxWidth * bandLow,
                    width: c.maxWidth * (bandHigh - bandLow),
                    top: 0,
                    bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppTheme.up.withValues(alpha: 0.30),
                        border: Border.symmetric(
                          vertical: BorderSide(
                              color: AppTheme.up.withValues(alpha: 0.8)),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    width: (c.maxWidth * tension).clamp(0.0, c.maxWidth),
                    top: 3,
                    bottom: 3,
                    child: Container(
                      decoration: BoxDecoration(
                        color: tension > bandHigh
                            ? AppTheme.down
                            : tension < bandLow
                                ? Colors.white54
                                : AppTheme.up,
                        borderRadius: BorderRadius.circular(5),
                        boxShadow: tension > bandHigh
                            ? [
                                const BoxShadow(
                                    color: AppTheme.down, blurRadius: 10)
                              ]
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// How close the fish is, and how much fight it has left in it.
class _DistanceBar extends StatelessWidget {
  const _DistanceBar({required this.progress, required this.staminaLeft});

  final double progress;
  final double staminaLeft;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('TO THE BOAT',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 9,
                    letterSpacing: 1.6,
                    fontWeight: FontWeight.w900)),
            const Spacer(),
            Text('${(progress * 100).round()}%',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w900)),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: Colors.black.withValues(alpha: 0.45),
            color: AppTheme.gold,
          ),
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: staminaLeft,
            minHeight: 3,
            backgroundColor: Colors.black.withValues(alpha: 0.35),
            color: Colors.white.withValues(alpha: 0.35),
          ),
        ),
      ],
    );
  }
}

/// Water, the line, and the shape under it. The shadow is the only thing you
/// see of the fish until it is in the boat.
class _FightPainter extends CustomPainter {
  _FightPainter({
    required this.phase,
    required this.elapsed,
    required this.progress,
    required this.tension,
    required this.surging,
    required this.shadowScale,
    required this.landed,
  });

  final _Phase phase;
  final double elapsed;
  final double progress;
  final double tension;
  final bool surging;
  final double shadowScale;
  final bool landed;

  @override
  void paint(Canvas canvas, Size size) {
    final t = elapsed / 1000.0;

    // Swells. They get choppier the harder the line is loaded.
    for (var layer = 0; layer < 3; layer++) {
      final paint = Paint()
        ..color = Colors.white.withValues(alpha: 0.05 + layer * 0.03)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      final baseY = size.height * (0.42 + layer * 0.16);
      final amplitude = 3.0 + layer * 2 + tension * 9 + (surging ? 6 : 0);
      final path = Path()..moveTo(0, baseY);
      for (double x = 0; x <= size.width; x += 6) {
        path.lineTo(
          x,
          baseY +
              math.sin((x / size.width * 4 * math.pi) + layer * 1.3 + t * 1.8) *
                  amplitude,
        );
      }
      canvas.drawPath(path, paint);
    }

    if (phase == _Phase.over && landed) return;

    // The fish tracks in from the far side as you gain on it, and yaws about
    // when it runs. Nothing here is authoritative — it mirrors state the server
    // already fixed at cast time.
    final near = phase == _Phase.waiting ? 0.0 : progress;
    final wobble = surging ? math.sin(t * 18) * 16 : math.sin(t * 3) * 5;
    final fx = size.width * (0.86 - 0.42 * near) + wobble;
    final fy = size.height * (0.74 - 0.16 * near) + math.sin(t * 2.2) * 6;

    final rodX = size.width * 0.12;
    final rodY = size.height * 0.16;
    final line = Paint()
      ..color = Colors.white.withValues(alpha: tension > 0.75 ? 0.85 : 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = tension > 0.75 ? 1.8 : 1.1;
    // A slack line bows; a loaded one goes straight, which is the tell you can
    // read without looking at the gauge.
    final sag = (1 - tension.clamp(0.0, 1.0)) * 34;
    final path = Path()
      ..moveTo(rodX, rodY)
      ..quadraticBezierTo(
          (rodX + fx) / 2, (rodY + fy) / 2 + sag, fx, fy);
    canvas.drawPath(path, line);

    final r = 13.0 + 30.0 * shadowScale;
    canvas.drawOval(
      Rect.fromCenter(center: Offset(fx, fy), width: r * 2.3, height: r),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
  }

  @override
  bool shouldRepaint(_FightPainter old) => true;
}
