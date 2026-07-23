import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../domain/crate.dart';

class CratesRepository {
  CratesRepository(this._client);

  final SupabaseClient _client;

  /// Unopened crates, live: refetch on any change to the player's crates so a
  /// freshly-granted one (streak milestone, etc.) pops in without a reload.
  Stream<List<Crate>> watchUnopenedCrates(String userId) {
    final controller = StreamController<List<Crate>>();
    RealtimeChannel? channel;
    Timer? debounce;

    Future<void> refresh() async {
      try {
        final rows = await _client
            .from('user_crates')
            .select('id, tier, source, granted_at')
            .eq('opened', false)
            .order('granted_at', ascending: true);
        controller.add(rows.map(Crate.fromJson).toList());
      } catch (error, stack) {
        controller.addError(error, stack);
      }
    }

    controller.onListen = () {
      refresh();
      channel = _client
          .channel('user_crates-$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'user_crates',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: userId,
            ),
            callback: (_) {
              debounce?.cancel();
              debounce = Timer(const Duration(milliseconds: 250), refresh);
            },
          )
          .subscribe();
    };
    controller.onCancel = () {
      debounce?.cancel();
      if (channel != null) _client.removeChannel(channel!);
    };
    return controller.stream;
  }

  Future<CrateReward> openCrate(String crateId) async {
    final json = await _client.rpc<Map<String, dynamic>>(
      'open_crate',
      params: {'p_crate_id': crateId},
    );
    return CrateReward.fromJson(json);
  }
}

final cratesRepositoryProvider = Provider<CratesRepository>(
  (ref) => CratesRepository(ref.watch(supabaseProvider)),
);

final unopenedCratesProvider = StreamProvider<List<Crate>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(const <Crate>[]);
  return ref.watch(cratesRepositoryProvider).watchUnopenedCrates(userId);
});
