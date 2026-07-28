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
            'hold_capacity, rare_bonus, sort_order')
        .order('sort_order');
    return rows.map(FishingGear.fromJson).toList();
  }

  Future<List<HoldItem>> fetchHold() async {
    final rows = await _client
        .from('fishery_hold')
        .select('id, species_code, weight_kg, value, was_active, caught_at')
        .order('caught_at', ascending: false);
    return rows.map(HoldItem.fromJson).toList();
  }

  Future<List<FishLogEntry>> fetchLog() async {
    final rows = await _client
        .from('user_fish_log')
        .select('species_code, catches, best_kg');
    return rows.map(FishLogEntry.fromJson).toList();
  }

  Future<CastResult> cast() async {
    final json = await _client.rpc<Map<String, dynamic>>('cast_line');
    return CastResult.fromJson(json);
  }

  Future<SaleResult> sell() async {
    final json = await _client.rpc<Map<String, dynamic>>('sell_catch');
    return SaleResult.fromJson(json);
  }

  Future<Map<String, dynamic>> buyGear(String code) =>
      _client.rpc<Map<String, dynamic>>('buy_fishing_gear',
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

/// Species keyed by code — what the hold, the log and the reveal card all need.
final fishSpeciesByCodeProvider = Provider<Map<String, FishSpecies>>((ref) {
  final list = ref.watch(fishSpeciesProvider).value ?? const <FishSpecies>[];
  return {for (final s in list) s.code: s};
});
