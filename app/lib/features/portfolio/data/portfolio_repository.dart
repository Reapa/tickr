import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/json.dart';
import '../../../core/supabase_providers.dart';
import '../domain/holding.dart';

/// A point on the portfolio-value-over-time chart.
class NetWorthPoint {
  const NetWorthPoint({required this.netWorth, required this.time});

  factory NetWorthPoint.fromJson(Map<String, dynamic> json) => NetWorthPoint(
        netWorth: jsonDouble(json['net_worth']),
        time: jsonDate(json['tick_at']),
      );

  final double netWorth;
  final DateTime time;
}

class OrderRow {
  const OrderRow({
    required this.assetId,
    required this.side,
    required this.quantity,
    required this.status,
    required this.rejectReason,
    required this.createdAt,
    this.realizedPnl,
    this.closeAvgCost,
    this.xpMultiplier,
  });

  factory OrderRow.fromJson(Map<String, dynamic> json) => OrderRow(
        assetId: json['asset_id'] as String,
        side: json['side'] as String,
        quantity: jsonDouble(json['quantity']),
        status: json['status'] as String,
        rejectReason: json['reject_reason'] as String?,
        createdAt: jsonDate(json['created_at']),
        realizedPnl: json['realized_pnl'] == null
            ? null
            : jsonDouble(json['realized_pnl']),
        closeAvgCost: json['close_avg_cost'] == null
            ? null
            : jsonDouble(json['close_avg_cost']),
        xpMultiplier: json['xp_multiplier'] == null
            ? null
            : jsonInt(json['xp_multiplier']),
      );

  final String assetId;
  final String side;
  final double quantity;
  final String status;
  final String? rejectReason;
  final DateTime createdAt;

  /// Cash profit (+) or loss (−) locked in by a closing sell. Null for buys,
  /// rejections, and pending orders.
  final double? realizedPnl;

  /// The position's average cost per unit at close — lets us show a return %.
  final double? closeAvgCost;

  /// XP multiplier on this close: 1 = flat, 2–10 = a "Sharp Trade" bonus roll.
  final int? xpMultiplier;

  bool get isSharpTrade => (xpMultiplier ?? 1) > 1;

  bool get isRealizedClose =>
      side == 'sell' && status == 'filled' && realizedPnl != null;

  /// Return on the closed lot: pnl / cost basis. Null when cost basis is absent.
  double? get realizedReturn {
    final pnl = realizedPnl;
    final avg = closeAvgCost;
    if (pnl == null || avg == null || avg * quantity == 0) return null;
    return pnl / (avg * quantity);
  }
}

/// A pending trigger order. On the sell side these are protection:
/// 'limit' = take profit, 'stop' = stop loss. On the buy side they are
/// "future" entry orders: 'limit' buys the dip, 'stop' buys the breakout.
class OpenOrder {
  const OpenOrder({
    required this.id,
    required this.assetId,
    required this.side,
    required this.orderType,
    required this.quantity,
    required this.limitPrice,
    this.trailOffset,
    this.trailIsPercent = false,
  });

  factory OpenOrder.fromJson(Map<String, dynamic> json) => OpenOrder(
        id: json['id'] as String,
        assetId: json['asset_id'] as String,
        side: json['side'] as String,
        orderType: json['order_type'] as String,
        quantity: jsonDouble(json['quantity']),
        limitPrice: jsonDouble(json['limit_price']),
        trailOffset:
            json['trail_offset'] == null ? null : jsonDouble(json['trail_offset']),
        trailIsPercent: json['trail_is_percent'] as bool? ?? false,
      );

  final String id;
  final String assetId;
  final String side;
  final String orderType;
  final double quantity;
  final double limitPrice;

  /// Set on a stop-loss that trails the price. A fraction (0.05 = 5%) when
  /// [trailIsPercent], otherwise a fixed price distance.
  final double? trailOffset;
  final bool trailIsPercent;

  bool get isTakeProfit => side == 'sell' && orderType == 'limit';
  bool get isStopLoss => side == 'sell' && orderType == 'stop';
  bool get isTrailingStop => isStopLoss && trailOffset != null;
  bool get isBuyEntry => side == 'buy';

  /// A short "5%" / "$2.50" summary of the trail distance, or null if fixed.
  String? get trailLabel {
    final t = trailOffset;
    if (t == null) return null;
    return trailIsPercent ? '${(t * 100).toStringAsFixed(t * 100 % 1 == 0 ? 0 : 1)}%'
        : '\$${t.toStringAsFixed(2)}';
  }

  /// Human label for the trigger kind.
  String get kindLabel => switch ((side, orderType)) {
        ('sell', 'limit') => 'Take profit',
        ('sell', 'stop') => isTrailingStop ? 'Trailing stop' : 'Stop loss',
        ('buy', 'limit') => 'Buy limit',
        ('buy', 'stop') => 'Buy stop',
        _ => 'Order',
      };
}

class PortfolioRepository {
  PortfolioRepository(this._client);

  final SupabaseClient _client;

  /// Live positions: authoritative refetch on every Realtime change.
  /// (Deliberately not .stream() — its client-side merge can duplicate rows
  /// when an INSERT event races the initial fetch; a refetch can't.)
  Stream<List<Holding>> watchHoldings(String userId) {
    final controller = StreamController<List<Holding>>();
    RealtimeChannel? channel;
    Timer? debounce;

    Future<void> refresh() async {
      try {
        final rows = await _client
            .from('holdings')
            .select('asset_id, quantity, avg_cost')
            .order('asset_id');
        controller.add(rows.map(Holding.fromJson).toList());
      } catch (error, stack) {
        controller.addError(error, stack);
      }
    }

    controller.onListen = () {
      refresh();
      channel = _client
          .channel('holdings-$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'holdings',
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

  Future<List<LedgerEntry>> fetchLedger({int limit = 50}) async {
    final rows = await _client
        .from('transactions')
        .select('type, cash_delta, asset_id, qty_delta, created_at')
        .order('created_at', ascending: false)
        .limit(limit);
    return rows.map(LedgerEntry.fromJson).toList();
  }

  Future<List<OrderRow>> fetchRecentOrders({int limit = 20}) async {
    final rows = await _client
        .from('orders')
        .select('asset_id, side, quantity, status, reject_reason, created_at, '
            'realized_pnl, close_avg_cost, xp_multiplier')
        .order('created_at', ascending: false)
        .limit(limit);
    return rows.map(OrderRow.fromJson).toList();
  }

  /// Live pending orders: refetch on every Realtime change to the user's
  /// orders. This is what makes a trailing stop's ratcheting level climb on
  /// screen — the tick engine raises `limit_price` and each change re-pulls.
  Stream<List<OpenOrder>> watchOpenOrders(String userId) {
    final controller = StreamController<List<OpenOrder>>();
    RealtimeChannel? channel;
    Timer? debounce;

    Future<void> refresh() async {
      try {
        final rows = await _client
            .from('orders')
            .select('id, asset_id, side, order_type, quantity, limit_price, '
                'trail_offset, trail_is_percent')
            .eq('status', 'pending')
            .order('created_at', ascending: true);
        controller.add(rows.map(OpenOrder.fromJson).toList());
      } catch (error, stack) {
        controller.addError(error, stack);
      }
    }

    controller.onListen = () {
      refresh();
      channel = _client
          .channel('orders-$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'orders',
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

  Future<List<NetWorthPoint>> fetchNetWorthHistory({
    // Fetch the full retained week so the chart's range chips can filter
    // client-side without extra round trips.
    Duration window = const Duration(days: 7),
  }) async {
    final since = DateTime.now().toUtc().subtract(window);
    final rows = await _client
        .from('net_worth_history')
        .select('net_worth, tick_at')
        .gte('tick_at', since.toIso8601String())
        .order('tick_at', ascending: true);
    return rows.map(NetWorthPoint.fromJson).toList();
  }
}

final portfolioRepositoryProvider = Provider<PortfolioRepository>(
  (ref) => PortfolioRepository(ref.watch(supabaseProvider)),
);

final holdingsProvider = StreamProvider<List<Holding>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(const <Holding>[]);
  return ref.watch(portfolioRepositoryProvider).watchHoldings(userId);
});

final ledgerProvider = FutureProvider<List<LedgerEntry>>(
  (ref) => ref.watch(portfolioRepositoryProvider).fetchLedger(),
);

final recentOrdersProvider = FutureProvider<List<OrderRow>>(
  (ref) => ref.watch(portfolioRepositoryProvider).fetchRecentOrders(),
);

final netWorthHistoryProvider = FutureProvider<List<NetWorthPoint>>(
  (ref) => ref.watch(portfolioRepositoryProvider).fetchNetWorthHistory(),
);

/// Pending TP/SL + queued buy orders across all positions, live so a trailing
/// stop's level updates on screen as the engine ratchets it.
final openOrdersProvider = StreamProvider<List<OpenOrder>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(const <OpenOrder>[]);
  return ref.watch(portfolioRepositoryProvider).watchOpenOrders(userId);
});
