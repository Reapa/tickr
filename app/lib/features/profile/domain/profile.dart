import '../../../core/json.dart';

/// The player's own profile row (also what leaderboards render for others).
class Profile {
  const Profile({
    required this.id,
    required this.displayName,
    required this.friendCode,
    required this.cashBalance,
    required this.netWorth,
    required this.xp,
    required this.level,
    required this.premiumBalance,
    required this.equipped,
    required this.streakDays,
    required this.longestStreak,
    required this.lastClaimDate,
  });

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        id: json['id'] as String,
        displayName: json['display_name'] as String,
        friendCode: json['friend_code'] as String,
        cashBalance: jsonDouble(json['cash_balance']),
        netWorth: jsonDouble(json['net_worth']),
        xp: jsonInt(json['xp']),
        level: jsonInt(json['level'], 1),
        premiumBalance: jsonInt(json['premium_balance']),
        equipped: (json['equipped'] as Map<String, dynamic>?) ?? const {},
        streakDays: jsonInt(json['streak_days']),
        longestStreak: jsonInt(json['longest_streak']),
        lastClaimDate: (json['last_claim_date'] as String?) == null
            ? null
            : DateTime.parse(json['last_claim_date'] as String),
      );

  final String id;
  final String displayName;
  final String friendCode;
  final double cashBalance;
  final double netWorth;
  final int xp;
  final int level;
  final int premiumBalance;
  final Map<String, dynamic> equipped;
  final int streakDays;
  final int longestStreak;
  final DateTime? lastClaimDate;

  /// Whether today's daily reward is still unclaimed (UTC day boundary,
  /// matching the server's claim_daily_reward()).
  bool get canClaimDaily {
    final today = DateTime.now().toUtc();
    final last = lastClaimDate;
    if (last == null) return true;
    return !(last.year == today.year &&
        last.month == today.month &&
        last.day == today.day);
  }

  /// XP progress toward the next level, 0..1 (level curve: 100·level²).
  double get levelProgress {
    final currentFloor = 100 * (level - 1) * (level - 1);
    final nextFloor = 100 * level * level;
    if (nextFloor == currentFloor) return 1;
    return ((xp - currentFloor) / (nextFloor - currentFloor)).clamp(0, 1);
  }
}
