import 'package:flutter/material.dart';

import '../cosmetics.dart';
import '../theme.dart';

/// A trader's avatar: the initial (or a custom [child]) inside their equipped
/// avatar-frame ring, with an optional level badge. Used everywhere a player is
/// shown — profile, leaderboards, podium, challenges — so cosmetics read
/// consistently across the app.
class TraderAvatar extends StatelessWidget {
  const TraderAvatar({
    super.key,
    required this.name,
    this.equipped,
    this.radius = 22,
    this.fallbackColor,
    this.child,
    this.level,
  });

  final String name;
  final Map<String, dynamic>? equipped;
  final double radius;

  /// Tint when no frame is equipped (e.g. podium medal colour).
  final Color? fallbackColor;

  /// Overrides the initial (e.g. a 👑 for a challenge winner).
  final Widget? child;

  /// When set, a small level pill is drawn at the bottom.
  final int? level;

  @override
  Widget build(BuildContext context) {
    final frame = equippedFrame(equipped);
    final tint = frame?.colors.first ?? fallbackColor ?? AppTheme.brand;

    final inner = CircleAvatar(
      radius: radius,
      backgroundColor: tint.withValues(alpha: 0.18),
      child: child ??
          Text(
            name.isEmpty ? '?' : name.characters.first.toUpperCase(),
            style: TextStyle(
              color: tint,
              fontWeight: FontWeight.w800,
              fontSize: radius * 0.82,
            ),
          ),
    );

    Widget avatar = inner;
    if (frame != null) {
      avatar = Container(
        padding: EdgeInsets.all(frame.width),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(colors: frame.colors),
          boxShadow: frame.glow == null
              ? null
              : [
                  BoxShadow(
                    color: frame.glow!.withValues(alpha: 0.55),
                    blurRadius: 10,
                    spreadRadius: 0.5,
                  ),
                ],
        ),
        child: inner,
      );
    }

    if (level == null) return avatar;
    return SizedBox(
      width: (radius + (frame?.width ?? 0)) * 2,
      height: (radius + (frame?.width ?? 0)) * 2 + 8,
      child: Stack(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: AppTheme.brand,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.surface, width: 2),
              ),
              child: Text('$level',
                  style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                      fontSize: 11)),
            ),
          ),
        ],
      ),
    );
  }
}

/// A player's name with their equipped badge emoji trailing it. Compact enough
/// for leaderboard rows and challenge cards.
class NameWithBadge extends StatelessWidget {
  const NameWithBadge({
    super.key,
    required this.name,
    this.equipped,
    this.style,
    this.badgeSize = 13,
  });

  final String name;
  final Map<String, dynamic>? equipped;
  final TextStyle? style;
  final double badgeSize;

  @override
  Widget build(BuildContext context) {
    final badge = equippedBadge(equipped);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(name,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        ),
        if (badge != null) ...[
          const SizedBox(width: 4),
          Text(badge, style: TextStyle(fontSize: badgeSize)),
        ],
      ],
    );
  }
}
