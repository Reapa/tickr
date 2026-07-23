import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/json.dart';
import '../../../core/supabase_providers.dart';
import '../domain/prediction.dart';

class PredictionsRepository {
  PredictionsRepository(this._client);

  final SupabaseClient _client;

  /// Open predictions paired with the player's own call, live: refetch on any
  /// change to predictions or the player's calls.
  Stream<List<OpenPrediction>> watchOpen(String userId) {
    final controller = StreamController<List<OpenPrediction>>();
    RealtimeChannel? preds;
    RealtimeChannel? mine;
    Timer? debounce;

    Future<void> refresh() async {
      try {
        final rows = await _client
            .from('predictions')
            .select('id, asset_id, question, closes_at, open_price, '
                'reward_xp, status, result, close_price')
            .eq('status', 'open')
            .order('closes_at', ascending: true);
        final calls = await _client
            .from('user_predictions')
            .select('prediction_id, choice');
        final choiceById = {
          for (final c in calls)
            c['prediction_id'] as String: c['choice'] as String,
        };
        controller.add([
          for (final r in rows)
            OpenPrediction(
              prediction: Prediction.fromJson(r),
              myChoice: choiceById[r['id'] as String],
            ),
        ]);
      } catch (error, stack) {
        controller.addError(error, stack);
      }
    }

    void bump() {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 250), refresh);
    }

    controller.onListen = () {
      refresh();
      preds = _client
          .channel('predictions-open')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'predictions',
            callback: (_) => bump(),
          )
          .subscribe();
      mine = _client
          .channel('user_predictions-$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'user_predictions',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: userId,
            ),
            callback: (_) => bump(),
          )
          .subscribe();
    };
    controller.onCancel = () {
      debounce?.cancel();
      if (preds != null) _client.removeChannel(preds!);
      if (mine != null) _client.removeChannel(mine!);
    };
    return controller.stream;
  }

  /// The player's calls the moment they resolve (correct flips non-null) — for
  /// a win/miss toast.
  Stream<PredictionResult> watchResults(String userId) {
    final controller = StreamController<PredictionResult>();
    final channel = _client
        .channel('user_predictions-results-$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'user_predictions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) {
            final row = payload.newRecord;
            if (row['correct'] == null) return;
            controller.add(PredictionResult(
              correct: row['correct'] as bool,
              awardedXp: jsonInt(row['awarded_xp']),
            ));
          },
        )
        .subscribe();
    controller.onCancel = () => _client.removeChannel(channel);
    return controller.stream;
  }

  Future<Map<String, dynamic>> makePrediction(String id, String choice) =>
      _client.rpc<Map<String, dynamic>>('make_prediction',
          params: {'p_prediction_id': id, 'p_choice': choice});
}

final predictionsRepositoryProvider = Provider<PredictionsRepository>(
  (ref) => PredictionsRepository(ref.watch(supabaseProvider)),
);

final openPredictionsProvider = StreamProvider<List<OpenPrediction>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(const <OpenPrediction>[]);
  return ref.watch(predictionsRepositoryProvider).watchOpen(userId);
});

final predictionResultsProvider = StreamProvider<PredictionResult>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return const Stream.empty();
  return ref.watch(predictionsRepositoryProvider).watchResults(userId);
});
