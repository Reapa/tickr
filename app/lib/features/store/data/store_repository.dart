import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/json.dart';
import '../../../core/supabase_providers.dart';

class Cosmetic {
  const Cosmetic({
    required this.code,
    required this.name,
    required this.description,
    required this.slot,
    required this.rarity,
    required this.pricePremium,
    required this.isSeasonReward,
  });

  factory Cosmetic.fromJson(Map<String, dynamic> json) => Cosmetic(
        code: json['code'] as String,
        name: json['name'] as String,
        description: (json['description'] as String?) ?? '',
        slot: json['slot'] as String,
        rarity: json['rarity'] as String,
        pricePremium: json['price_premium'] == null
            ? null
            : jsonInt(json['price_premium']),
        isSeasonReward: (json['is_season_reward'] as bool?) ?? false,
      );

  final String code;
  final String name;
  final String description;
  final String slot;
  final String rarity;

  /// null = not purchasable (season reward).
  final int? pricePremium;
  final bool isSeasonReward;
}

/// The cosmetic-only store. Premium currency cannot buy trading advantage —
/// that's a database constraint, not a UI promise.
class StoreRepository {
  StoreRepository(this._client);

  final SupabaseClient _client;

  Future<List<Cosmetic>> fetchCosmetics() async {
    final rows = await _client.from('cosmetics').select();
    final list = rows.map(Cosmetic.fromJson).toList()
      ..sort((a, b) => (a.pricePremium ?? 1 << 30)
          .compareTo(b.pricePremium ?? 1 << 30));
    return list;
  }

  Future<Set<String>> fetchOwnedCosmeticCodes() async {
    final rows = await _client
        .from('user_cosmetics')
        .select('cosmetics(code)');
    return rows
        .map((row) => ((row['cosmetics'] as Map<String, dynamic>?)?['code'])
            as String?)
        .whereType<String>()
        .toSet();
  }

  Future<Map<String, dynamic>> purchaseCosmetic(String code) =>
      _client.rpc<Map<String, dynamic>>('purchase_cosmetic',
          params: {'p_code': code});

  Future<void> equipCosmetic(String slot, String? code) =>
      _client.rpc<void>('equip_cosmetic', params: {
        'p_slot': slot,
        'p_code': code,
      });

  /// v1 store stub: grants gems without payment. Replaced by real IAP
  /// receipt validation later (see README roadmap).
  Future<Map<String, dynamic>> stubPurchasePremium(String package) =>
      _client.rpc<Map<String, dynamic>>('stub_purchase_premium',
          params: {'p_package': package});
}

final storeRepositoryProvider = Provider<StoreRepository>(
  (ref) => StoreRepository(ref.watch(supabaseProvider)),
);

final cosmeticsProvider = FutureProvider<List<Cosmetic>>(
  (ref) => ref.watch(storeRepositoryProvider).fetchCosmetics(),
);

final ownedCosmeticsProvider = FutureProvider<Set<String>>(
  (ref) => ref.watch(storeRepositoryProvider).fetchOwnedCosmeticCodes(),
);
