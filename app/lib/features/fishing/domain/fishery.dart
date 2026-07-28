import 'package:flutter/material.dart';

import '../../../core/json.dart';

/// Rarity drives colour, sound and celebration everywhere in the fishery, so it
/// gets a real type rather than a bare string.
enum FishRarity {
  common('Common', Color(0xFF9AA5B1)),
  uncommon('Uncommon', Color(0xFF4CAF7D)),
  rare('Rare', Color(0xFF4A9EE7)),
  epic('Epic', Color(0xFFB06AE0)),
  legendary('Legendary', Color(0xFFFFB020));

  const FishRarity(this.label, this.color);

  final String label;
  final Color color;

  static FishRarity parse(String? code) => switch (code) {
        'uncommon' => FishRarity.uncommon,
        'rare' => FishRarity.rare,
        'epic' => FishRarity.epic,
        'legendary' => FishRarity.legendary,
        _ => FishRarity.common,
      };

  /// Epic and legendary are the moments worth stopping the screen for.
  bool get isSpecial => index >= FishRarity.epic.index;
}

/// A catchable species from the server catalog.
class FishSpecies {
  const FishSpecies({
    required this.code,
    required this.name,
    required this.rarity,
    required this.valuePerKg,
    required this.minWeightKg,
    required this.maxWeightKg,
    required this.minBoatTier,
    required this.blurb,
    required this.sortOrder,
  });

  factory FishSpecies.fromJson(Map<String, dynamic> json) => FishSpecies(
        code: json['code'] as String,
        name: json['name'] as String,
        rarity: FishRarity.parse(json['rarity'] as String?),
        valuePerKg: jsonDouble(json['value_per_kg']),
        minWeightKg: jsonDouble(json['min_weight_kg']),
        maxWeightKg: jsonDouble(json['max_weight_kg']),
        minBoatTier: jsonInt(json['min_boat_tier']),
        blurb: (json['blurb'] as String?) ?? '',
        sortOrder: jsonInt(json['sort_order']),
      );

  final String code;
  final String name;
  final FishRarity rarity;
  final double valuePerKg;
  final double minWeightKg;
  final double maxWeightKg;
  final int minBoatTier;
  final String blurb;
  final int sortOrder;
}

/// A boat or a rod from the gear catalog.
class FishingGear {
  const FishingGear({
    required this.code,
    required this.kind,
    required this.tier,
    required this.name,
    required this.description,
    required this.price,
    required this.catchPerHour,
    required this.holdCapacity,
    required this.rareBonus,
    required this.sortOrder,
  });

  factory FishingGear.fromJson(Map<String, dynamic> json) => FishingGear(
        code: json['code'] as String,
        kind: json['kind'] as String,
        tier: jsonInt(json['tier']),
        name: json['name'] as String,
        description: json['description'] as String,
        price: jsonDouble(json['price']),
        catchPerHour: jsonDouble(json['catch_per_hour']),
        holdCapacity: jsonInt(json['hold_capacity']),
        rareBonus: jsonDouble(json['rare_bonus']),
        sortOrder: jsonInt(json['sort_order']),
      );

  final String code;
  final String kind; // 'boat' | 'rod'
  final int tier;
  final String name;
  final String description;
  final double price;
  final double catchPerHour;
  final int holdCapacity;
  final double rareBonus;
  final int sortOrder;

  bool get isBoat => kind == 'boat';

  /// Roughly how long this boat takes to fill its hold from empty — the number
  /// that actually tells a player when to come back.
  Duration get timeToFill => catchPerHour <= 0
      ? Duration.zero
      : Duration(minutes: (holdCapacity / catchPerHour * 60).round());
}

/// The player's fishery state, as returned by `get_my_fishery`.
class Fishery {
  const Fishery({
    required this.boatCode,
    required this.boatName,
    required this.boatTier,
    required this.rodCode,
    required this.rodName,
    required this.rodTier,
    required this.catchPerHour,
    required this.holdCapacity,
    required this.bait,
    required this.baitCap,
    required this.baitSeconds,
    required this.nextBaitAt,
    required this.lifetimeCatches,
    required this.lifetimeValue,
    required this.gearValue,
    required this.holdCount,
    required this.holdValue,
  });

  factory Fishery.fromJson(Map<String, dynamic> json) => Fishery(
        boatCode: json['boat_code'] as String,
        boatName: json['boat_name'] as String,
        boatTier: jsonInt(json['boat_tier']),
        rodCode: json['rod_code'] as String,
        rodName: json['rod_name'] as String,
        rodTier: jsonInt(json['rod_tier']),
        catchPerHour: jsonDouble(json['catch_per_hour']),
        holdCapacity: jsonInt(json['hold_capacity']),
        bait: jsonInt(json['bait']),
        baitCap: jsonInt(json['bait_cap']),
        baitSeconds: jsonInt(json['bait_seconds']),
        nextBaitAt: json['next_bait_at'] == null
            ? null
            : jsonDate(json['next_bait_at']),
        lifetimeCatches: jsonInt(json['lifetime_catches']),
        lifetimeValue: jsonDouble(json['lifetime_value']),
        gearValue: jsonDouble(json['gear_value']),
        holdCount: jsonInt(json['hold_count']),
        holdValue: jsonDouble(json['hold_value']),
      );

  final String boatCode;
  final String boatName;
  final int boatTier;
  final String rodCode;
  final String rodName;
  final int rodTier;
  final double catchPerHour;
  final int holdCapacity;
  final int bait;
  final int baitCap;
  final int baitSeconds;
  final DateTime? nextBaitAt;
  final int lifetimeCatches;
  final double lifetimeValue;
  final double gearValue;
  final int holdCount;
  final double holdValue;

  bool get holdIsFull => holdCount >= holdCapacity;
  bool get hasBait => bait > 0;
  bool get canCast => hasBait && !holdIsFull;

  double get holdFraction =>
      holdCapacity <= 0 ? 0 : (holdCount / holdCapacity).clamp(0, 1).toDouble();

  /// When the hold will be full at the current catch rate — the whole reason
  /// to come back later rather than sit and watch.
  Duration? get timeToFull {
    if (holdIsFull || catchPerHour <= 0) return null;
    final remaining = holdCapacity - holdCount;
    return Duration(minutes: (remaining / catchPerHour * 60).round());
  }
}

/// A single fish sitting in the hold.
class HoldItem {
  const HoldItem({
    required this.id,
    required this.speciesCode,
    required this.weightKg,
    required this.value,
    required this.wasActive,
    required this.caughtAt,
  });

  factory HoldItem.fromJson(Map<String, dynamic> json) => HoldItem(
        id: json['id'] as String,
        speciesCode: json['species_code'] as String,
        weightKg: jsonDouble(json['weight_kg']),
        value: jsonDouble(json['value']),
        wasActive: (json['was_active'] as bool?) ?? false,
        caughtAt: jsonDate(json['caught_at']),
      );

  final String id;
  final String speciesCode;
  final double weightKg;
  final double value;
  final bool wasActive;
  final DateTime caughtAt;
}

/// The result of one hand-cast.
class CastResult {
  const CastResult({
    required this.status,
    this.reason,
    this.speciesCode,
    this.name,
    this.rarity = FishRarity.common,
    this.blurb = '',
    this.weightKg = 0,
    this.value = 0,
    this.bait = 0,
    this.hold = 0,
    this.holdCapacity = 0,
    this.isPersonalBest = false,
  });

  factory CastResult.fromJson(Map<String, dynamic> json) => CastResult(
        status: json['status'] as String,
        reason: json['reason'] as String?,
        speciesCode: json['species'] as String?,
        name: json['name'] as String?,
        rarity: FishRarity.parse(json['rarity'] as String?),
        blurb: (json['blurb'] as String?) ?? '',
        weightKg: jsonDouble(json['weight_kg']),
        value: jsonDouble(json['value']),
        bait: jsonInt(json['bait']),
        hold: jsonInt(json['hold']),
        holdCapacity: jsonInt(json['hold_capacity']),
        isPersonalBest: (json['is_personal_best'] as bool?) ?? false,
      );

  final String status; // caught | rejected
  final String? reason;
  final String? speciesCode;
  final String? name;
  final FishRarity rarity;
  final String blurb;
  final double weightKg;
  final double value;
  final int bait;
  final int hold;
  final int holdCapacity;
  final bool isPersonalBest;

  bool get isCatch => status == 'caught';
}

/// The result of selling the hold.
class SaleResult {
  const SaleResult({
    required this.status,
    required this.total,
    required this.count,
    this.bestName,
    this.bestValue = 0,
    this.bestKg = 0,
  });

  factory SaleResult.fromJson(Map<String, dynamic> json) => SaleResult(
        status: json['status'] as String,
        total: jsonDouble(json['total']),
        count: jsonInt(json['count']),
        bestName: json['best_name'] as String?,
        bestValue: jsonDouble(json['best_value']),
        bestKg: jsonDouble(json['best_kg']),
      );

  final String status; // sold | empty
  final double total;
  final int count;
  final String? bestName;
  final double bestValue;
  final double bestKg;

  bool get isSold => status == 'sold';
}

/// One line of the permanent catch record.
class FishLogEntry {
  const FishLogEntry({
    required this.speciesCode,
    required this.catches,
    required this.bestKg,
  });

  factory FishLogEntry.fromJson(Map<String, dynamic> json) => FishLogEntry(
        speciesCode: json['species_code'] as String,
        catches: jsonInt(json['catches']),
        bestKg: jsonDouble(json['best_kg']),
      );

  final String speciesCode;
  final int catches;
  final double bestKg;
}
