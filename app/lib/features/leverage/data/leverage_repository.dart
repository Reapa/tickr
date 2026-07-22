import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../domain/leveraged_position.dart';

/// An auto-close the tick engine just executed (liquidation / TP / SL).
class LeveragedClose {
  const LeveragedClose({
    required this.assetId,
    required this.side,
    required this.leverage,
    required this.closeReason,
    required this.realizedPnl,
  });

  final String assetId;
  final String side;
  final int leverage;
  final String closeReason;
  final double realizedPnl;
}

class LeverageRepository {
  LeverageRepository(this._client);

  final SupabaseClient _client;

  static const _columns = 'id, asset_id, side, leverage, quantity, '
      'entry_price, margin, liquidation_price, take_profit, stop_loss, '
      'status, realized_pnl, close_reason';

  Future<List<LeveragedPosition>> fetchPositions({int closedLimit = 5}) async {
    final open = await _client
        .from('leveraged_positions')
        .select(_columns)
        .eq('status', 'open')
        .order('opened_at', ascending: false);
    final closed = await _client
        .from('leveraged_positions')
        .select(_columns)
        .neq('status', 'open')
        .order('closed_at', ascending: false)
        .limit(closedLimit);
    return [...open, ...closed].map(LeveragedPosition.fromJson).toList();
  }

  /// Fetch + Realtime refetch (same pattern as holdings).
  Stream<List<LeveragedPosition>> watchPositions(String userId) {
    final controller = StreamController<List<LeveragedPosition>>();
    RealtimeChannel? channel;
    Timer? debounce;

    Future<void> refresh() async {
      try {
        controller.add(await fetchPositions());
      } catch (error, stack) {
        controller.addError(error, stack);
      }
    }

    controller.onListen = () {
      refresh();
      channel = _client
          .channel('lev-positions-$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'leveraged_positions',
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

  /// Streams tick-engine auto-closes for toast notifications.
  Stream<LeveragedClose> watchCloses(String userId) {
    final controller = StreamController<LeveragedClose>();
    final channel = _client
        .channel('lev-closes-$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'leveraged_positions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) {
            final row = payload.newRecord;
            final reason = row['close_reason'] as String?;
            if (row['status'] != 'open' && reason != null && reason != 'manual') {
              controller.add(LeveragedClose(
                assetId: row['asset_id'] as String,
                side: row['side'] as String,
                leverage: (row['leverage'] as num).toInt(),
                closeReason: reason,
                realizedPnl: (row['realized_pnl'] as num?)?.toDouble() ?? 0,
              ));
            }
          },
        )
        .subscribe();
    controller.onCancel = () => _client.removeChannel(channel);
    return controller.stream;
  }

  Future<Map<String, dynamic>> openPosition({
    required String assetId,
    required String side,
    required int leverage,
    required double margin,
  }) =>
      _client.rpc<Map<String, dynamic>>('open_leveraged_position', params: {
        'p_asset_id': assetId,
        'p_side': side,
        'p_leverage': leverage,
        'p_margin': margin,
      });

  Future<Map<String, dynamic>> closePosition(String positionId) =>
      _client.rpc<Map<String, dynamic>>('close_leveraged_position',
          params: {'p_position_id': positionId});

  Future<Map<String, dynamic>> setProtection({
    required String positionId,
    double? takeProfit,
    double? stopLoss,
  }) =>
      _client.rpc<Map<String, dynamic>>('set_leveraged_protection', params: {
        'p_position_id': positionId,
        'p_take_profit': takeProfit,
        'p_stop_loss': stopLoss,
      });

  /// A trailing stop that ratchets the position's stop-loss toward profit.
  /// [trail] is a fraction when [isPercent] (0.05 = 5%), else a price distance.
  Future<Map<String, dynamic>> setTrailingStop({
    required String positionId,
    required double trail,
    required bool isPercent,
  }) =>
      _client
          .rpc<Map<String, dynamic>>('set_leveraged_trailing_stop', params: {
        'p_position_id': positionId,
        'p_trail': trail,
        'p_is_percent': isPercent,
      });
}

final leverageRepositoryProvider = Provider<LeverageRepository>(
  (ref) => LeverageRepository(ref.watch(supabaseProvider)),
);

/// Open + recently closed leveraged positions, live.
final leveragedPositionsProvider =
    StreamProvider<List<LeveragedPosition>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(const []);
  return ref.watch(leverageRepositoryProvider).watchPositions(userId);
});

/// Tick-engine auto-closes (liquidations, TP, SL) for app-wide toasts.
final leveragedClosesProvider = StreamProvider<LeveragedClose>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return const Stream.empty();
  return ref.watch(leverageRepositoryProvider).watchCloses(userId);
});
