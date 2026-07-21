import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../data/market_repository.dart';

/// Recent close prices for sparklines: 24 five-minute candles (~2h),
/// refreshed every 90s — cheap enough to draw on every market-list tile.
final sparklineProvider =
    FutureProvider.autoDispose.family<List<double>, String>((ref, assetId) {
  final timer = Timer(const Duration(seconds: 90), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref
      .watch(marketRepositoryProvider)
      .fetchCandles(assetId, 300, limit: 24)
      .then((candles) => [for (final c in candles) c.close]);
});

/// A tiny trend line — the market list's heartbeat.
class Sparkline extends ConsumerWidget {
  const Sparkline({super.key, required this.assetId, this.width = 56});

  final String assetId;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final points = ref.watch(sparklineProvider(assetId)).value;
    if (points == null || points.length < 2) {
      return SizedBox(width: width, height: 24);
    }
    final rising = points.last >= points.first;
    return CustomPaint(
      size: Size(width, 24),
      painter: _SparklinePainter(
        points: points,
        color: rising ? AppTheme.up : AppTheme.down,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.points, required this.color});

  final List<double> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    var lo = points.first, hi = points.first;
    for (final p in points) {
      if (p < lo) lo = p;
      if (p > hi) hi = p;
    }
    final range = hi - lo;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = size.width * i / (points.length - 1);
      final y = range == 0
          ? size.height / 2
          : size.height - (points[i] - lo) / range * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round,
    );
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.25), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.points != points || old.color != color;
}
