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
    required this.cadence,
    required this.rewardCash,
    required this.rewardXp,
    required this.rewardGems,
    required this.completed,
    required this.completedAt,
    required this.expiresAt,
    required this.sortOrder,
  });

  final String code;
  final String title;
  final String description;
  final String concept;

  /// 'permanent' (milestones), 'daily', or 'weekly'.
  final String cadence;
  final double rewardCash;
  final int rewardXp;
  final int rewardGems;
  final bool completed;
  final DateTime? completedAt;

  /// When this cycle resets; null for permanent milestones.
  final DateTime? expiresAt;
  final int sortOrder;
}

class MissionsRepository {
  MissionsRepository(this._client);

  final SupabaseClient _client;

  Future<List<MissionStatus>> fetchMissions() async {
    // Make sure this cycle's daily/weekly board is assigned before we read it,
    // and re-evaluate so freshly-rolled missions reflect play already done.
    await _client.rpc<void>('refresh_my_missions');

    final rows = await _client.from('user_missions').select(
        'status, completed_at, cadence, expires_at, '
        'missions(code, title, description, concept, reward_cash, '
        'reward_xp, reward_gems, sort_order)');

    final now = DateTime.now().toUtc();
    final list = <MissionStatus>[];
    for (final row in rows) {
      final m = row['missions'] as Map<String, dynamic>;
      final expiresAt =
          row['expires_at'] == null ? null : jsonDate(row['expires_at']);
      // Hide a lapsed cycle's missions until the rotation swaps them out.
      if (expiresAt != null && expiresAt.isBefore(now)) continue;
      list.add(MissionStatus(
        code: m['code'] as String,
        title: m['title'] as String,
        description: m['description'] as String,
        concept: m['concept'] as String,
        cadence: row['cadence'] as String,
        rewardCash: jsonDouble(m['reward_cash']),
        rewardXp: jsonInt(m['reward_xp']),
        rewardGems: jsonInt(m['reward_gems']),
        completed: row['status'] == 'completed',
        completedAt: row['completed_at'] == null
            ? null
            : jsonDate(row['completed_at']),
        expiresAt: expiresAt,
        sortOrder: jsonInt(m['sort_order']),
      ));
    }
    return list;
  }
}

final missionsRepositoryProvider = Provider<MissionsRepository>(
  (ref) => MissionsRepository(ref.watch(supabaseProvider)),
);

final missionsProvider = FutureProvider<List<MissionStatus>>(
  (ref) => ref.watch(missionsRepositoryProvider).fetchMissions(),
);
