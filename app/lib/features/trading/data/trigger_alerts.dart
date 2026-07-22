import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/json.dart';
import '../../../core/supabase_providers.dart';

/// A take-profit or stop-loss that the server just executed for this player.
class TriggerFill {
  const TriggerFill({
    required this.assetId,
    required this.orderType,
    required this.quantity,
    this.realizedPnl,
    this.xpMultiplier,
  });

  final String assetId;
  final String orderType; // limit = TP, stop = SL
  final double quantity;

  /// Cash profit (+) / loss (−) the fill locked in (from the orders row).
  final double? realizedPnl;

  /// XP multiplier on the fill: 1 = flat, 2–10 = a "Sharp Trade" bonus.
  final int? xpMultiplier;

  bool get isTakeProfit => orderType == 'limit';
}

/// Streams the player's TP/SL fills via Realtime so the app can toast them
/// the moment the tick engine executes one — even mid-scroll on another tab.
final triggerFillsProvider = StreamProvider<TriggerFill>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  final client = ref.watch(supabaseProvider);
  if (userId == null) return const Stream.empty();

  final controller = StreamController<TriggerFill>();
  final channel = client
      .channel('orders-fills-$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'orders',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'user_id',
          value: userId,
        ),
        callback: (payload) {
          final row = payload.newRecord;
          // Only protective sells (TP/SL/trailing) — a buy-limit/stop entry is
          // also order_type 'limit'/'stop', and would otherwise be mislabelled
          // as a take-profit here.
          if (row['status'] == 'filled' &&
              row['order_type'] != 'market' &&
              row['side'] == 'sell') {
            controller.add(TriggerFill(
              assetId: row['asset_id'] as String,
              orderType: row['order_type'] as String,
              quantity: jsonDouble(row['quantity']),
              realizedPnl: row['realized_pnl'] == null
                  ? null
                  : jsonDouble(row['realized_pnl']),
              xpMultiplier: row['xp_multiplier'] == null
                  ? null
                  : jsonInt(row['xp_multiplier']),
            ));
          }
        },
      )
      .subscribe();
  ref.onDispose(() {
    client.removeChannel(channel);
    controller.close();
  });
  return controller.stream;
});
