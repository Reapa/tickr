import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../domain/profile.dart';

class ProfileRepository {
  ProfileRepository(this._client);

  final SupabaseClient _client;

  /// The player's own profile, live (net worth moves every tick).
  Stream<Profile?> watchProfile(String userId) => _client
      .from('profiles')
      .stream(primaryKey: ['id'])
      .eq('id', userId)
      .map((rows) => rows.isEmpty ? null : Profile.fromJson(rows.first));

  Future<Set<String>> fetchUnlockedClassIds() async {
    final rows = await _client
        .from('user_asset_class_unlocks')
        .select('class_id');
    return rows.map((row) => row['class_id'] as String).toSet();
  }

  Future<void> updateDisplayName(String name) =>
      _client.rpc<void>('update_display_name', params: {'p_name': name});

  Future<Map<String, dynamic>> claimDailyReward() =>
      _client.rpc<Map<String, dynamic>>('claim_daily_reward');
}

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(ref.watch(supabaseProvider)),
);

/// The signed-in player's live profile.
final myProfileProvider = StreamProvider<Profile?>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(null);
  return ref.watch(profileRepositoryProvider).watchProfile(userId);
});

/// Which asset classes the player has bought into.
final unlockedClassesProvider = FutureProvider<Set<String>>(
  (ref) => ref.watch(profileRepositoryProvider).fetchUnlockedClassIds(),
);
