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
  });

  final String assetId;
  final String orderType; // limit = TP, stop = SL
  final double quantity;

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
          if (row['status'] == 'filled' && row['order_type'] != 'market') {
            controller.add(TriggerFill(
              assetId: row['asset_id'] as String,
              orderType: row['order_type'] as String,
              quantity: jsonDouble(row['quantity']),
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
