import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../domain/fishery.dart';

/// Read/write side of the fishery. Every mutation is a SECURITY DEFINER RPC —
/// the client never decides what it caught or what it's worth.
class FishingRepository {
  FishingRepository(this._client);

  final SupabaseClient _client;

  /// One round trip for the whole screen. The RPC also accrues idle catches and
  /// regenerates bait, so simply opening the page brings you up to date.
  Future<Fishery> fetchFishery() async {
    final json = await _client.rpc<Map<String, dynamic>>('get_my_fishery');
    return Fishery.fromJson(json);
  }

  Future<List<FishSpecies>> fetchSpecies() async {
    final rows = await _client
        .from('fish_species')
        .select('code, name, rarity, value_per_kg, min_weight_kg, '
            'max_weight_kg, min_boat_tier, blurb, sort_order')
        .order('sort_order');
    return rows.map(FishSpecies.fromJson).toList();
  }

  Future<List<FishingGear>> fetchGear() async {
    final rows = await _client
        .from('fishing_gear')
        .select('code, kind, tier, name, description, price, catch_per_hour, '
            'hold_capacity, rare_bonus, sort_order, req_species_logged, '
            'req_legendary, req_best_kg, req_label')
        .order('sort_order');
    return rows.map(FishingGear.fromJson).toList();
  }

  Future<List<FishingSpot>> fetchSpots() async {
    final rows = await _client
        .from('fishing_spots')
        .select('code, name, min_boat_tier, trip_casts, fight_scale, '
            'haul_cap, blurb, sort_order')
        .order('sort_order');
    return rows.map(FishingSpot.fromJson).toList();
  }

  Future<List<FishingSupply>> fetchSupplies() async {
    final rows = await _client
        .from('fishing_supplies')
        .select('code, name, description, price, uses, sort_order')
        .order('sort_order');
    return rows.map(FishingSupply.fromJson).toList();
  }

  /// The sellable hold only. Well fish are tagged to a live trip and are not
  /// yours until you bank them.
  Future<List<HoldItem>> fetchHold() async {
    final rows = await _client
        .from('fishery_hold')
        .select('id, species_code, weight_kg, value, was_active, caught_at')
        .isFilter('trip_id', null)
        .order('caught_at', ascending: false);
    return rows.map(HoldItem.fromJson).toList();
  }

  Future<List<FishLogEntry>> fetchLog() async {
    final rows = await _client
        .from('user_fish_log')
        .select('species_code, catches, best_kg');
    return rows.map(FishLogEntry.fromJson).toList();
  }

  Future<Map<String, dynamic>> startTrip(String spot) =>
      _client.rpc<Map<String, dynamic>>('start_trip',
          params: {'p_spot': spot});

  /// Hooks something. The server has already decided what it is and what it is
  /// worth; all that comes back is the fight to play.
  Future<Hookup> cast() async {
    final json = await _client.rpc<Map<String, dynamic>>('cast_line');
    return Hookup.fromJson(json);
  }

  /// Reports how the fight went. The server clamps what that can be worth —
  /// see the migration header for why this boundary sits on the client.
  Future<LandResult> resolve({
    required String encounterId,
    required bool landed,
    required double score,
  }) async {
    final json = await _client.rpc<Map<String, dynamic>>(
      'resolve_encounter',
      params: {
        'p_encounter': encounterId,
        'p_landed': landed,
        'p_score': score,
      },
    );
    return LandResult.fromJson(json);
  }

  Future<HaulResult> bankHaul() async {
    final json = await _client.rpc<Map<String, dynamic>>('bank_haul');
    return HaulResult.fromJson(json);
  }

  Future<SaleResult> sell() async {
    final json = await _client.rpc<Map<String, dynamic>>('sell_catch');
    return SaleResult.fromJson(json);
  }

  Future<Map<String, dynamic>> buyGear(String code) =>
      _client.rpc<Map<String, dynamic>>('buy_fishing_gear',
          params: {'p_code': code});

  Future<Map<String, dynamic>> buySupply(String code, {int qty = 1}) =>
      _client.rpc<Map<String, dynamic>>('buy_fishing_supply',
          params: {'p_code': code, 'p_qty': qty});

  Future<Map<String, dynamic>> useSupply(String code) =>
      _client.rpc<Map<String, dynamic>>('use_fishing_supply',
          params: {'p_code': code});
}

final fishingRepositoryProvider = Provider<FishingRepository>(
  (ref) => FishingRepository(ref.watch(supabaseProvider)),
);

/// Live fishery state. Invalidated after every action, and on app resume.
final fisheryProvider = FutureProvider<Fishery>(
  (ref) => ref.watch(fishingRepositoryProvider).fetchFishery(),
);

final fisheryHoldProvider = FutureProvider<List<HoldItem>>(
  (ref) => ref.watch(fishingRepositoryProvider).fetchHold(),
);

final fishLogProvider = FutureProvider<List<FishLogEntry>>(
  (ref) => ref.watch(fishingRepositoryProvider).fetchLog(),
);

/// Catalogs never change at runtime, so they're fetched once and kept.
final fishSpeciesProvider = FutureProvider<List<FishSpecies>>(
  (ref) => ref.watch(fishingRepositoryProvider).fetchSpecies(),
);

final fishingGearProvider = FutureProvider<List<FishingGear>>(
  (ref) => ref.watch(fishingRepositoryProvider).fetchGear(),
);

final fishingSpotsProvider = FutureProvider<List<FishingSpot>>(
  (ref) => ref.watch(fishingRepositoryProvider).fetchSpots(),
);

final fishingSuppliesProvider = FutureProvider<List<FishingSupply>>(
  (ref) => ref.watch(fishingRepositoryProvider).fetchSupplies(),
);

/// Species keyed by code — what the hold, the log and the reveal card all need.
final fishSpeciesByCodeProvider = Provider<Map<String, FishSpecies>>((ref) {
  final list = ref.watch(fishSpeciesProvider).value ?? const <FishSpecies>[];
  return {for (final s in list) s.code: s};
});
