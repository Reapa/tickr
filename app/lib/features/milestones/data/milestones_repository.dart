import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../domain/milestone.dart';

class MilestonesRepository {
  MilestonesRepository(this._client);

  final SupabaseClient _client;

  Future<List<Milestone>> fetchCatalog() async {
    final rows = await _client
        .from('milestones')
        .select('id, net_worth, title, crate_tier, reward_xp, sort_order')
        .order('sort_order', ascending: true);
    return rows.map(Milestone.fromJson).toList();
  }

  Future<Set<int>> fetchReached() async {
    final rows =
        await _client.from('user_milestones').select('milestone_id');
    return {for (final r in rows) (r['milestone_id'] as num).toInt()};
  }

  /// Claim any newly-reached milestones (grants crate + XP server-side).
  Future<List<ReachedMilestone>> claim() async {
    final json = await _client.rpc<Map<String, dynamic>>('claim_milestones');
    final list = (json['newly_reached'] as List?) ?? const [];
    return list
        .cast<Map<String, dynamic>>()
        .map(ReachedMilestone.fromJson)
        .toList();
  }
}

final milestonesRepositoryProvider = Provider<MilestonesRepository>(
  (ref) => MilestonesRepository(ref.watch(supabaseProvider)),
);

final milestonesCatalogProvider = FutureProvider<List<Milestone>>(
  (ref) => ref.watch(milestonesRepositoryProvider).fetchCatalog(),
);

final reachedMilestonesProvider = FutureProvider<Set<int>>(
  (ref) => ref.watch(milestonesRepositoryProvider).fetchReached(),
);
