import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../domain/property.dart';

class PropertiesRepository {
  PropertiesRepository(this._client);

  final SupabaseClient _client;

  Stream<List<Property>> watchMyProperties(String userId) => _client
      .from('user_properties')
      .stream(primaryKey: ['id'])
      .eq('user_id', userId)
      .map((rows) => [
            for (final r in rows)
              if ((r['status'] as String?) != 'sold') Property.fromJson(r),
          ]);

  Future<List<PropertyType>> fetchTypes() async {
    final rows = await _client
        .from('property_types')
        .select()
        .order('sort_order', ascending: true);
    return rows.map(PropertyType.fromJson).toList();
  }

  Future<List<PropertyListing>> fetchListings() async {
    final rows = await _client
        .from('property_listings')
        .select()
        .eq('available', true)
        .order('value', ascending: true);
    return rows.map(PropertyListing.fromJson).toList();
  }

  Future<Map<String, dynamic>> buy(String listingId) =>
      _client.rpc<Map<String, dynamic>>('buy_property',
          params: {'p_listing': listingId});

  Future<Map<String, dynamic>> sell(String propertyId) =>
      _client.rpc<Map<String, dynamic>>('sell_property',
          params: {'p_property': propertyId});
}

final propertiesRepositoryProvider = Provider<PropertiesRepository>(
  (ref) => PropertiesRepository(ref.watch(supabaseProvider)),
);

final myPropertiesProvider = StreamProvider<List<Property>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(const <Property>[]);
  return ref.watch(propertiesRepositoryProvider).watchMyProperties(userId);
});

final propertyTypesProvider = FutureProvider<List<PropertyType>>(
  (ref) => ref.watch(propertiesRepositoryProvider).fetchTypes(),
);

final propertyListingsProvider = FutureProvider<List<PropertyListing>>(
  (ref) => ref.watch(propertiesRepositoryProvider).fetchListings(),
);
