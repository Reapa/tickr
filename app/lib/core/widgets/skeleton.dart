import 'package:flutter/material.dart';

import '../theme.dart';

/// Slides a [LinearGradient] horizontally to create the shimmer sweep.
class _Slide extends GradientTransform {
  const _Slide(this.t);
  final double t;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * t, 0, 0);
}

/// A single shimmering placeholder block.
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width = double.infinity,
    this.height = 14,
    this.radius = 6,
  });

  final double width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = AppTheme.surfaceHigh;
    final highlight = Color.lerp(base, Colors.white, 0.06)!;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            colors: [base, highlight, base],
            stops: const [0.35, 0.5, 0.65],
            transform: _Slide(_c.value * 3 - 1.5),
          ),
        ),
      ),
    );
  }
}

/// A list of row-shaped skeletons that mimics the market / leaderboard layout.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 7});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: rows,
      itemBuilder: (context, _) => Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.radius),
          border: Border.all(color: AppTheme.hairline),
        ),
        child: Row(
          children: [
            const Skeleton(width: 44, height: 44, radius: 11),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Skeleton(width: 90, height: 13),
                  SizedBox(height: 7),
                  Skeleton(width: 140, height: 10),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Skeleton(width: 56, height: 14),
                SizedBox(height: 7),
                Skeleton(width: 40, height: 10),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
