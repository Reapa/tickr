import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Fire a full-screen celebration burst (confetti + a scaling banner) over
/// everything. Self-dismisses. Used for level-ups and other milestones.
void showCelebration(
  BuildContext context, {
  required String title,
  required String subtitle,
  String emoji = '🎉',
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _Celebration(
      title: title,
      subtitle: subtitle,
      emoji: emoji,
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _Celebration extends StatefulWidget {
  const _Celebration({
    required this.title,
    required this.subtitle,
    required this.emoji,
    required this.onDone,
  });

  final String title;
  final String subtitle;
  final String emoji;
  final VoidCallback onDone;

  @override
  State<_Celebration> createState() => _CelebrationState();
}

class _CelebrationState extends State<_Celebration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();
    final rng = Random();
    const colors = [
      AppTheme.up,
      AppTheme.accent,
      Colors.amber,
      Colors.pinkAccent,
      Colors.purpleAccent,
    ];
    _particles = List.generate(80, (_) {
      return _Particle(
        x: rng.nextDouble(),
        angle: rng.nextDouble() * 2 * pi,
        speed: 0.5 + rng.nextDouble() * 1.1,
        color: colors[rng.nextInt(colors.length)],
        size: 5 + rng.nextDouble() * 7,
        spin: (rng.nextDouble() - 0.5) * 12,
      );
    });
    _c.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Overlay entries have no Material ancestor, which paints text with the
    // debug yellow double-underline. A transparent Material fixes that without
    // adding any visible surface.
    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          // Banner scales in, holds, fades out.
          final bannerOpacity = t < 0.15
              ? t / 0.15
              : t > 0.8
                  ? (1 - (t - 0.8) / 0.2)
                  : 1.0;
          final bannerScale = 0.7 + Curves.elasticOut.transform(min(t / 0.4, 1)) * 0.3;
          return Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _ConfettiPainter(_particles, t),
                ),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Opacity(
                    opacity: bannerOpacity.clamp(0, 1),
                    child: Transform.scale(
                      scale: bannerScale,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 340),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceHigh,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                                color: AppTheme.brand.withValues(alpha: 0.6),
                                width: 1.5),
                            boxShadow: [
                              BoxShadow(
                                color: AppTheme.brand.withValues(alpha: 0.35),
                                blurRadius: 48,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 72,
                                height: 72,
                                alignment: Alignment.center,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [AppTheme.accent, AppTheme.up],
                                  ),
                                ),
                                child: Text(widget.emoji,
                                    style: const TextStyle(fontSize: 38)),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                widget.title,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 26,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.5),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                widget.subtitle,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.grey.shade300,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
      ),
    );
  }
}

class _Particle {
  _Particle({
    required this.x,
    required this.angle,
    required this.speed,
    required this.color,
    required this.size,
    required this.spin,
  });

  final double x; // 0..1 horizontal launch position
  final double angle;
  final double speed;
  final Color color;
  final double size;
  final double spin;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.particles, this.t);

  final List<_Particle> particles;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final p in particles) {
      // Launch upward/outward from top-center, then gravity pulls down.
      final startX = size.width * p.x;
      final dist = p.speed * size.height * 0.9 * t;
      final dx = cos(p.angle) * dist * 0.5;
      final dy = sin(p.angle) * dist * 0.3 + 0.9 * size.height * t * t;
      final pos = Offset(startX + dx, size.height * 0.15 + dy - dist * 0.4);
      paint.color = p.color.withValues(alpha: (1 - t).clamp(0, 1));
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(p.spin * t);
      canvas.drawRect(
        Rect.fromCenter(
            center: Offset.zero, width: p.size, height: p.size * 0.6),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}
