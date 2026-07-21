import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/json.dart';
import '../../../core/supabase_providers.dart';

/// A mission joined with the player's progress on it.
class MissionStatus {
  const MissionStatus({
    required this.code,
    required this.title,
    required this.description,
    required this.concept,
    required this.rewardCash,
    required this.rewardXp,
    required this.completed,
    required this.completedAt,
  });

  final String code;
  final String title;
  final String description;
  final String concept;
  final double rewardCash;
  final int rewardXp;
  final bool completed;
  final DateTime? completedAt;
}

class MissionsRepository {
  MissionsRepository(this._client);

  final SupabaseClient _client;

  Future<List<MissionStatus>> fetchMissions() async {
    final missions = await _client
        .from('missions')
        .select('id, code, title, description, concept, reward_cash, '
            'reward_xp, sort_order')
        .eq('is_active', true)
        .order('sort_order', ascending: true);
    final mine = await _client
        .from('user_missions')
        .select('mission_id, status, completed_at');
    final mineById = {
      for (final row in mine) row['mission_id'] as String: row,
    };
    return missions.map((m) {
      final progress = mineById[m['id'] as String];
      return MissionStatus(
        code: m['code'] as String,
        title: m['title'] as String,
        description: m['description'] as String,
        concept: m['concept'] as String,
        rewardCash: jsonDouble(m['reward_cash']),
        rewardXp: jsonInt(m['reward_xp']),
        completed: progress?['status'] == 'completed',
        completedAt: progress?['completed_at'] == null
            ? null
            : jsonDate(progress!['completed_at']),
      );
    }).toList();
  }
}

final missionsRepositoryProvider = Provider<MissionsRepository>(
  (ref) => MissionsRepository(ref.watch(supabaseProvider)),
);

final missionsProvider = FutureProvider<List<MissionStatus>>(
  (ref) => ref.watch(missionsRepositoryProvider).fetchMissions(),
);
