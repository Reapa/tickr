import '../../../core/json.dart';

/// An unopened reward crate in a player's inventory. Cosmetics + XP only.
class Crate {
  const Crate({
    required this.id,
    required this.tier,
    required this.source,
    required this.grantedAt,
  });

  factory Crate.fromJson(Map<String, dynamic> json) => Crate(
        id: json['id'] as String,
        tier: json['tier'] as String,
        source: json['source'] as String,
        grantedAt: jsonDate(json['granted_at']),
      );

  final String id;
  final String tier; // common | rare | legendary
  final String source; // welcome | streak | ...
  final DateTime grantedAt;
}

/// What opening a crate revealed.
class CrateReward {
  const CrateReward({
    required this.status,
    this.tier,
    this.kind,
    this.xp,
    this.code,
    this.name,
    this.rarity,
    this.slot,
    this.reason,
  });

  factory CrateReward.fromJson(Map<String, dynamic> json) => CrateReward(
        status: json['status'] as String,
        tier: json['tier'] as String?,
        kind: json['kind'] as String?, // xp | cosmetic
        xp: json['xp'] == null ? null : jsonInt(json['xp']),
        code: json['code'] as String?,
        name: json['name'] as String?,
        rarity: json['rarity'] as String?,
        slot: json['slot'] as String?,
        reason: json['reason'] as String?,
      );

  final String status; // opened | rejected
  final String? tier;
  final String? kind;
  final int? xp;
  final String? code;
  final String? name;
  final String? rarity;
  final String? slot;
  final String? reason;

  bool get isCosmetic => kind == 'cosmetic';
}
