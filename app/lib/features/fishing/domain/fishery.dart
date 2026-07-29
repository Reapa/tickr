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
    required this.reqSpeciesLogged,
    required this.reqLegendary,
    required this.reqBestKg,
    required this.reqLabel,
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
        reqSpeciesLogged: jsonInt(json['req_species_logged']),
        reqLegendary: (json['req_legendary'] as bool?) ?? false,
        reqBestKg: jsonDouble(json['req_best_kg']),
        reqLabel: (json['req_label'] as String?) ?? '',
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

  /// The licence. Earned from the catch log, never bought — this is what stops
  /// a rich trader clearing the whole ladder in one sitting.
  final int reqSpeciesLogged;
  final bool reqLegendary;
  final double reqBestKg;
  final String reqLabel;

  bool get isBoat => kind == 'boat';

  bool get hasLicenceGate =>
      reqSpeciesLogged > 0 || reqLegendary || reqBestKg > 0;

  /// Whether the catch log has already earned this one.
  bool licenceMet(Licence l) =>
      l.speciesLogged >= reqSpeciesLogged &&
      (!reqLegendary || l.hasLegendary) &&
      l.bestKg >= reqBestKg;

  /// How close the log is, 0..1 — so a locked upgrade shows a bar rather than
  /// just a refusal.
  double licenceProgress(Licence l) {
    if (!hasLicenceGate) return 1;
    if (reqSpeciesLogged > 0) {
      return (l.speciesLogged / reqSpeciesLogged).clamp(0, 1).toDouble();
    }
    if (reqBestKg > 0) return (l.bestKg / reqBestKg).clamp(0, 1).toDouble();
    return l.hasLegendary ? 1 : 0;
  }

  /// Roughly how long this boat takes to fill its hold from empty — the number
  /// that actually tells a player when to come back.
  Duration get timeToFill => catchPerHour <= 0
      ? Duration.zero
      : Duration(minutes: (holdCapacity / catchPerHour * 60).round());
}

/// Somewhere to fish. A spot is its own species table, its own fight length and
/// its own trip length, which is what makes choosing one a decision.
class FishingSpot {
  const FishingSpot({
    required this.code,
    required this.name,
    required this.minBoatTier,
    required this.tripCasts,
    required this.fightScale,
    required this.haulCap,
    required this.blurb,
    required this.sortOrder,
  });

  factory FishingSpot.fromJson(Map<String, dynamic> json) => FishingSpot(
        code: json['code'] as String,
        name: json['name'] as String,
        minBoatTier: jsonInt(json['min_boat_tier']),
        tripCasts: jsonInt(json['trip_casts']),
        fightScale: jsonDouble(json['fight_scale']),
        haulCap: jsonDouble(json['haul_cap']),
        blurb: (json['blurb'] as String?) ?? '',
        sortOrder: jsonInt(json['sort_order']),
      );

  final String code;
  final String name;
  final int minBoatTier;
  final int tripCasts;
  final double fightScale;
  final double haulCap;
  final String blurb;
  final int sortOrder;
}

/// A consumable. Bought with cash and burned — the fishery's only real sink.
class FishingSupply {
  const FishingSupply({
    required this.code,
    required this.name,
    required this.description,
    required this.price,
    required this.uses,
    required this.sortOrder,
  });

  factory FishingSupply.fromJson(Map<String, dynamic> json) => FishingSupply(
        code: json['code'] as String,
        name: json['name'] as String,
        description: json['description'] as String,
        price: jsonDouble(json['price']),
        uses: jsonInt(json['uses']),
        sortOrder: jsonInt(json['sort_order']),
      );

  final String code;
  final String name;
  final String description;
  final double price;
  final int uses;
  final int sortOrder;

  IconData get icon => switch (code) {
        'chum' => Icons.grain,
        'live_bait' => Icons.bug_report,
        _ => Icons.link,
      };
}

/// What the catch log has earned you. Cash cannot buy any of it.
class Licence {
  const Licence({
    required this.speciesLogged,
    required this.hasLegendary,
    required this.bestKg,
  });

  factory Licence.fromJson(Map<String, dynamic>? json) => Licence(
        speciesLogged: jsonInt(json?['species_logged']),
        hasLegendary: (json?['has_legendary'] as bool?) ?? false,
        bestKg: jsonDouble(json?['best_kg']),
      );

  final int speciesLogged;
  final bool hasLegendary;
  final double bestKg;
}

/// A trip in progress: the live well, the casts left, and the haul bonus that
/// grows with every fish you land and dies with the one you lose.
class Trip {
  const Trip({
    required this.id,
    required this.spotCode,
    required this.spotName,
    required this.castsUsed,
    required this.tripCasts,
    required this.landed,
    required this.lost,
    required this.streak,
    required this.bestStreak,
    required this.chumCasts,
    required this.baitCasts,
    required this.spareLines,
    required this.haulBonus,
    required this.wellCount,
    required this.wellValue,
  });

  factory Trip.fromJson(Map<String, dynamic> json) => Trip(
        id: json['id'] as String,
        spotCode: json['spot_code'] as String,
        spotName: (json['spot_name'] as String?) ?? '',
        castsUsed: jsonInt(json['casts_used']),
        tripCasts: jsonInt(json['trip_casts']),
        landed: jsonInt(json['landed']),
        lost: jsonInt(json['lost']),
        streak: jsonInt(json['streak']),
        bestStreak: jsonInt(json['best_streak']),
        chumCasts: jsonInt(json['chum_casts']),
        baitCasts: jsonInt(json['bait_casts']),
        spareLines: jsonInt(json['spare_lines']),
        haulBonus: jsonDouble(json['haul_bonus']),
        wellCount: jsonInt(json['well_count']),
        wellValue: jsonDouble(json['well_value']),
      );

  final String id;
  final String spotCode;
  final String spotName;
  final int castsUsed;
  final int tripCasts;
  final int landed;
  final int lost;
  final int streak;
  final int bestStreak;
  final int chumCasts;
  final int baitCasts;
  final int spareLines;
  final double haulBonus;
  final int wellCount;
  final double wellValue;

  int get castsLeft => (tripCasts - castsUsed).clamp(0, tripCasts);
  bool get isSpent => castsLeft <= 0;

  /// What banking right now would actually pay, bonus included.
  double get bankableValue => wellValue;
}

/// Every number the client needs to play out one fight. The server derives all
/// of it from the fish, the rod and the spot; the client only animates it.
class FightProfile {
  const FightProfile({
    required this.biteMs,
    required this.hookWindowMs,
    required this.staminaMs,
    required this.strength,
    required this.relaxRate,
    required this.reelRate,
    required this.slipRate,
    required this.bandLow,
    required this.bandHigh,
    required this.overMult,
    required this.surgeRate,
    required this.runs,
    required this.runMs,
    required this.shadow,
    required this.difficulty,
    this.snags = 0,
    this.snagMs = 0,
    this.dives = 0,
    this.diveMs = 0,
    this.divePull = 0,
    this.bandDecay = 0,
  });

  factory FightProfile.fromJson(Map<String, dynamic> json) => FightProfile(
        biteMs: jsonInt(json['bite_ms']),
        hookWindowMs: jsonInt(json['hook_window_ms']),
        staminaMs: jsonInt(json['stamina_ms']),
        strength: jsonDouble(json['strength']),
        relaxRate: jsonDouble(json['relax_rate']),
        reelRate: jsonDouble(json['reel_rate']),
        slipRate: jsonDouble(json['slip_rate']),
        bandLow: jsonDouble(json['band_low']),
        bandHigh: jsonDouble(json['band_high']),
        overMult: json['over_mult'] == null ? 1.8 : jsonDouble(json['over_mult']),
        surgeRate: json['surge_rate'] == null
            ? jsonDouble(json['relax_rate']) + 0.35 * jsonDouble(json['strength'])
            : jsonDouble(json['surge_rate']),
        runs: jsonInt(json['runs']),
        runMs: json['run_ms'] == null ? 900 : jsonInt(json['run_ms']),
        shadow: (json['shadow'] as String?) ?? 'small',
        difficulty: jsonDouble(json['difficulty']),
        // All default to zero, so an encounter rolled by a server that predates
        // per-spot mechanics plays exactly the fight it always did.
        snags: jsonInt(json['snags']),
        snagMs: jsonInt(json['snag_ms']),
        dives: jsonInt(json['dives']),
        diveMs: jsonInt(json['dive_ms']),
        divePull: jsonDouble(json['dive_pull']),
        bandDecay: jsonDouble(json['band_decay']),
      );

  final int biteMs;
  final int hookWindowMs;
  final int staminaMs;
  final double strength;
  final double relaxRate;
  final double reelRate;
  final double slipRate;
  final double bandLow;
  final double bandHigh;

  /// How much faster the line loads once you push past [bandHigh]. This is what
  /// stops "hold the button down" being a strategy.
  final double overMult;

  /// Tension added per second while the fish is running. Pitched just above
  /// [relaxRate], so easing off slows a run without ever stopping it.
  final double surgeRate;
  final int runs;

  /// How long one run lasts. Scaled to the fight, not a flat number of
  /// seconds — see the migration note.
  final int runMs;
  final String shadow;
  final double difficulty;

  /// Structure windows. While one is open the fish is making for something it
  /// can break you off on, and a SLACK line loses it — the opposite of what a
  /// run asks for, which is the whole point of having both.
  final int snags;
  final int snagMs;

  /// Sounding runs. Progress bleeds at [divePull] per second for [diveMs], and
  /// unlike a run it adds no tension of its own, so you wind through it.
  final int dives;
  final int diveMs;
  final double divePull;

  /// How far the top of the safe band falls across a whole fight — a leader
  /// wearing through on ice or coral.
  final double bandDecay;

  bool get hasSnags => snags > 0 && snagMs > 0;
  bool get hasDives => dives > 0 && diveMs > 0;

  /// How big the shape under the boat looks. The only clue you get before the
  /// fish is actually in it.
  double get shadowScale => switch (shadow) {
        'huge' => 1.0,
        'big' => 0.62,
        _ => 0.34,
      };

  String get shadowLabel => switch (shadow) {
        'huge' => 'Something enormous',
        'big' => 'Something big',
        _ => 'Something small',
      };
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
    required this.stowedCount,
    required this.tripsCompleted,
    required this.bestHaul,
    required this.lastSpotCode,
    required this.licence,
    required this.supplies,
    required this.trip,
    required this.hookup,
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
        stowedCount: jsonInt(json['stowed_count']),
        tripsCompleted: jsonInt(json['trips_completed']),
        bestHaul: jsonDouble(json['best_haul']),
        lastSpotCode: json['last_spot_code'] as String?,
        licence: Licence.fromJson(json['licence'] as Map<String, dynamic>?),
        supplies: {
          for (final e in ((json['supplies'] as Map<String, dynamic>?) ?? {})
              .entries)
            e.key: jsonInt(e.value),
        },
        trip: json['trip'] == null
            ? null
            : Trip.fromJson(json['trip'] as Map<String, dynamic>),
        // A hook that survived a page refresh: the fight is resumable.
        hookup: json['encounter'] == null
            ? null
            : Hookup.fromJson({
                ...json['encounter'] as Map<String, dynamic>,
                'status': 'hooked',
              }),
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

  /// Everything physically aboard, well included — this is what the hold cap
  /// actually measures, whereas [holdCount] is only what you may sell.
  final int stowedCount;
  final int tripsCompleted;
  final double bestHaul;
  final String? lastSpotCode;
  final Licence licence;
  final Map<String, int> supplies;
  final Trip? trip;
  final Hookup? hookup;

  bool get isOnTrip => trip != null;

  /// Measured against everything aboard, not just the sellable part: a live
  /// well still takes up room in the boat.
  bool get holdIsFull => stowedCount >= holdCapacity;
  bool get hasBait => bait > 0;
  bool get canCast =>
      hasBait && !holdIsFull && isOnTrip && !(trip?.isSpent ?? true);

  double get holdFraction => holdCapacity <= 0
      ? 0
      : (stowedCount / holdCapacity).clamp(0, 1).toDouble();

  /// When the hold will be full at the current catch rate — the whole reason
  /// to come back later rather than sit and watch.
  Duration? get timeToFull {
    if (holdIsFull || catchPerHour <= 0) return null;
    final remaining = holdCapacity - stowedCount;
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

/// The result of a cast: something is on the line, and this is everything you
/// are told about it until you have it in the boat.
class Hookup {
  const Hookup({
    required this.status,
    this.reason,
    this.encounterId,
    this.fight,
    this.bait = 0,
    this.castsUsed = 0,
    this.tripCasts = 0,
    this.expiresAt,
  });

  factory Hookup.fromJson(Map<String, dynamic> json) => Hookup(
        status: json['status'] as String,
        reason: json['reason'] as String?,
        encounterId: json['encounter_id'] as String?,
        fight: json['fight'] == null
            ? null
            : FightProfile.fromJson(json['fight'] as Map<String, dynamic>),
        bait: jsonInt(json['bait']),
        castsUsed: jsonInt(json['casts_used']),
        tripCasts: jsonInt(json['trip_casts']),
        expiresAt: json['expires_at'] == null
            ? null
            : jsonDate(json['expires_at']),
      );

  final String status; // hooked | rejected
  final String? reason;
  final String? encounterId;
  final FightProfile? fight;
  final int bait;
  final int castsUsed;
  final int tripCasts;
  final DateTime? expiresAt;

  bool get isHooked => status == 'hooked' && fight != null;
}

/// How the fight ended. Landing is the first moment the species, the weight
/// and the money are known — everything before this was a shadow.
class LandResult {
  const LandResult({
    required this.status,
    this.reason,
    this.speciesCode,
    this.name,
    this.rarity = FishRarity.common,
    this.blurb = '',
    this.weightKg = 0,
    this.value = 0,
    this.perfect = false,
    this.score = 0,
    this.streak = 0,
    this.haulBonus = 1,
    this.isPersonalBest = false,
    this.saved = false,
    this.spilled = false,
  });

  factory LandResult.fromJson(Map<String, dynamic> json) => LandResult(
        status: json['status'] as String,
        reason: json['reason'] as String?,
        speciesCode: json['species'] as String?,
        name: json['name'] as String?,
        rarity: FishRarity.parse(json['rarity'] as String?),
        blurb: (json['blurb'] as String?) ?? '',
        weightKg: jsonDouble(json['weight_kg']),
        value: jsonDouble(json['value']),
        perfect: (json['perfect'] as bool?) ?? false,
        score: jsonDouble(json['score']),
        streak: jsonInt(json['streak']),
        haulBonus: json['haul_bonus'] == null ? 1 : jsonDouble(json['haul_bonus']),
        isPersonalBest: (json['is_personal_best'] as bool?) ?? false,
        saved: (json['saved'] as bool?) ?? false,
        spilled: (json['spilled'] as bool?) ?? false,
      );

  final String status; // landed | lost | rejected
  final String? reason;
  final String? speciesCode;
  final String? name;
  final FishRarity rarity;
  final String blurb;
  final double weightKg;
  final double value;
  final bool perfect;
  final double score;
  final int streak;
  final double haulBonus;
  final bool isPersonalBest;
  final bool saved;
  final bool spilled;

  bool get isCatch => status == 'landed';
}

/// The receipt for banking a trip.
class HaulResult {
  const HaulResult({
    required this.status,
    this.reason,
    this.count = 0,
    this.total = 0,
    this.haulBonus = 1,
    this.landed = 0,
    this.lost = 0,
    this.bestStreak = 0,
  });

  factory HaulResult.fromJson(Map<String, dynamic> json) => HaulResult(
        status: json['status'] as String,
        reason: json['reason'] as String?,
        count: jsonInt(json['count']),
        total: jsonDouble(json['total']),
        haulBonus: json['haul_bonus'] == null ? 1 : jsonDouble(json['haul_bonus']),
        landed: jsonInt(json['landed']),
        lost: jsonInt(json['lost']),
        bestStreak: jsonInt(json['best_streak']),
      );

  final String status; // banked | rejected
  final String? reason;
  final int count;
  final double total;
  final double haulBonus;
  final int landed;
  final int lost;
  final int bestStreak;

  bool get isBanked => status == 'banked';
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
