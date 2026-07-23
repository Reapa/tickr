import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../domain/user_income.dart';

class IncomeRepository {
  IncomeRepository(this._client);

  final SupabaseClient _client;

  /// The player's pending/lifetime income, live — the pending buckets tick up
  /// as the server accrual cron runs.
  Stream<UserIncome> watchIncome(String userId) => _client
      .from('user_income')
      .stream(primaryKey: ['user_id'])
      .eq('user_id', userId)
      .map((rows) =>
          rows.isEmpty ? UserIncome.empty : UserIncome.fromJson(rows.first));

  /// Sweep all pending income into cash. Server accrues up-to-the-second first.
  Future<IncomeCollected> collect() async {
    final res = await _client.rpc<Map<String, dynamic>>('collect_income');
    return IncomeCollected.fromJson(res);
  }
}

final incomeRepositoryProvider = Provider<IncomeRepository>(
  (ref) => IncomeRepository(ref.watch(supabaseProvider)),
);

final incomeProvider = StreamProvider<UserIncome>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(UserIncome.empty);
  return ref.watch(incomeRepositoryProvider).watchIncome(userId);
});
