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

/// One of your fills, plotted on the price chart at the moment and price it
/// happened. Distinct from [ChartMarker], which draws a horizontal price LEVEL
/// — this is a point in time.
class TradeMark {
  const TradeMark({
    required this.side,
    required this.quantity,
    required this.price,
    required this.at,
  });

  factory TradeMark.fromJson(Map<String, dynamic> json) => TradeMark(
        side: json['side'] as String,
        quantity: jsonDouble(json['quantity']),
        price: jsonDouble(json['price']),
        at: jsonDate(json['created_at']),
      );

  final String side; // buy | sell
  final double quantity;
  final double price;
  final DateTime at;

  bool get isBuy => side == 'buy';
}

/// One row of personal activity. Spot orders and leveraged positions live in
/// separate tables server-side; `get_my_recent_trades` unions them into this
/// single shape so realized P/L shows for both (see migration
/// 20260722000026_leverage_activity).
class OrderRow {
  const OrderRow({
    required this.assetId,
    required this.side,
    required this.quantity,
    required this.status,
    required this.rejectReason,
    required this.createdAt,
    this.kind = 'spot',
    this.realizedPnl,
    this.closeAvgCost,
    this.xpMultiplier,
    this.leverage,
    this.closeReason,
  });

  factory OrderRow.fromJson(Map<String, dynamic> json) => OrderRow(
        assetId: json['asset_id'] as String,
        side: json['side'] as String,
        quantity: jsonDouble(json['quantity']),
        status: json['status'] as String,
        rejectReason: json['reject_reason'] as String?,
        // The unioned feed names the timestamp `at`; keep `created_at` working
        // for anything still reading the orders table directly.
        createdAt: jsonDate(json['at'] ?? json['created_at']),
        kind: (json['kind'] as String?) ?? 'spot',
        realizedPnl: json['realized_pnl'] == null
            ? null
            : jsonDouble(json['realized_pnl']),
        closeAvgCost: (json['cost_basis'] ?? json['close_avg_cost']) == null
            ? null
            : jsonDouble(json['cost_basis'] ?? json['close_avg_cost']),
        xpMultiplier: json['xp_multiplier'] == null
            ? null
            : jsonInt(json['xp_multiplier']),
        leverage: json['leverage'] == null ? null : jsonInt(json['leverage']),
        closeReason: json['close_reason'] as String?,
      );

  final String assetId;
  final String side;
  final double quantity;
  final String status;
  final String? rejectReason;
  final DateTime createdAt;

  /// 'spot' (an order) or 'leverage' (a margin position).
  final String kind;

  /// Cash profit (+) or loss (−) locked in by a close. Null for entries,
  /// rejections, and still-open positions.
  final double? realizedPnl;

  /// Cost basis at close: average cost PER UNIT for spot, total margin staked
  /// for a leveraged position. [realizedReturn] handles the difference.
  final double? closeAvgCost;

  /// XP multiplier on this close: 1 = flat, 2–10 = a "Sharp Trade" bonus roll.
  final int? xpMultiplier;

  /// Leverage multiple, leveraged rows only.
  final int? leverage;

  /// How a leveraged position ended: manual | take_profit | stop_loss |
  /// liquidation.
  final String? closeReason;

  bool get isLeverage => kind == 'leverage';

  bool get isSharpTrade => (xpMultiplier ?? 1) > 1;

  bool get isLiquidation => status == 'liquidated';

  bool get isRealizedClose => realizedPnl != null &&
      (isLeverage
          ? (status == 'closed' || status == 'liquidated')
          : side == 'sell' && status == 'filled');

  /// Return on what was actually risked: cost basis for spot, margin staked
  /// for leverage — the only figure that means anything at 50x.
  double? get realizedReturn {
    final pnl = realizedPnl;
    final basis = closeAvgCost;
    if (pnl == null || basis == null) return null;
    final denominator = isLeverage ? basis : basis * quantity;
    if (denominator == 0) return null;
    return pnl / denominator;
  }

  /// Human label for the action, e.g. "Long 50×" or "Buy".
  String get actionLabel {
    if (!isLeverage) return side == 'buy' ? 'Buy' : 'Sell';
    final dir = side == 'long' ? 'Long' : 'Short';
    return leverage == null ? dir : '$dir $leverage×';
  }

  /// Why a leveraged position ended, when it's worth saying out loud.
  String? get outcomeLabel => switch (closeReason) {
        'liquidation' => 'Liquidated',
        'take_profit' => 'Take profit',
        'stop_loss' => 'Stop loss',
        _ => null,
      };
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

  /// Spot orders AND leveraged positions in one chronological list. Reads the
  /// server-side union rather than `orders` directly, because leveraged trades
  /// never write an order row and were previously missing entirely.
  Future<List<OrderRow>> fetchRecentOrders({int limit = 20}) async {
    final rows = await _client.rpc<List<dynamic>>(
      'get_my_recent_trades',
      params: {'p_limit': limit},
    );
    return rows
        .cast<Map<String, dynamic>>()
        .map(OrderRow.fromJson)
        .toList();
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

  /// Your own fills on one asset, newest first — the points plotted on the
  /// candle chart so you can see where you actually got in and out.
  Future<List<TradeMark>> fetchMyTrades(String assetId, {int limit = 60}) async {
    final rows = await _client
        .from('trades')
        .select('side, quantity, price, created_at')
        .eq('asset_id', assetId)
        .order('created_at', ascending: false)
        .limit(limit);
    return rows.map(TradeMark.fromJson).toList();
  }

  /// The net-worth chart series, bucketed server-side.
  ///
  /// This used to select the whole retained week straight from the table with
  /// no limit. At tick resolution that was ~121,000 rows per player — several
  /// megabytes downloaded to a phone to draw a chart a few hundred pixels
  /// wide. The RPC returns at most [buckets] points whatever the range, so the
  /// payload is set by the chart's resolution rather than by how long someone
  /// has been playing. The range chips still filter client-side from this.
  Future<List<NetWorthPoint>> fetchNetWorthHistory({
    Duration window = const Duration(days: 7),
    int buckets = 300,
  }) async {
    final rows = await _client.rpc<List<dynamic>>(
      'get_net_worth_series',
      params: {'p_hours': window.inHours, 'p_buckets': buckets},
    );
    return rows
        .cast<Map<String, dynamic>>()
        .map(NetWorthPoint.fromJson)
        .toList();
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

/// Your fills on one asset, for the chart's trade markers.
final myTradesProvider =
    FutureProvider.family<List<TradeMark>, String>((ref, assetId) async {
  // Re-pulls whenever an order completes, so a fresh buy shows up immediately.
  ref.watch(recentOrdersProvider);
  return ref.watch(portfolioRepositoryProvider).fetchMyTrades(assetId);
});

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
