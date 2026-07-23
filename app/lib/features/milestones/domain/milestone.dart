import '../../../core/json.dart';

/// A rung on the net-worth progression ladder.
class Milestone {
  const Milestone({
    required this.id,
    required this.netWorth,
    required this.title,
    required this.crateTier,
    required this.rewardXp,
    required this.sortOrder,
  });

  factory Milestone.fromJson(Map<String, dynamic> json) => Milestone(
        id: jsonInt(json['id']),
        netWorth: jsonDouble(json['net_worth']),
        title: json['title'] as String,
        crateTier: json['crate_tier'] as String,
        rewardXp: jsonInt(json['reward_xp']),
        sortOrder: jsonInt(json['sort_order']),
      );

  final int id;
  final double netWorth;
  final String title;
  final String crateTier;
  final int rewardXp;
  final int sortOrder;
}

/// A milestone the player just crossed (returned by claim_milestones).
class ReachedMilestone {
  const ReachedMilestone({
    required this.title,
    required this.netWorth,
    required this.crateTier,
    required this.xp,
  });

  factory ReachedMilestone.fromJson(Map<String, dynamic> json) =>
      ReachedMilestone(
        title: json['title'] as String,
        netWorth: jsonDouble(json['net_worth']),
        crateTier: json['crate_tier'] as String,
        xp: jsonInt(json['xp']),
      );

  final String title;
  final double netWorth;
  final String crateTier;
  final int xp;
}
