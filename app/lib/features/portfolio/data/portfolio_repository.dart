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
  });

  factory OrderRow.fromJson(Map<String, dynamic> json) => OrderRow(
        assetId: json['asset_id'] as String,
        side: json['side'] as String,
        quantity: jsonDouble(json['quantity']),
        status: json['status'] as String,
        rejectReason: json['reject_reason'] as String?,
        createdAt: jsonDate(json['created_at']),
      );

  final String assetId;
  final String side;
  final double quantity;
  final String status;
  final String? rejectReason;
  final DateTime createdAt;
}

/// A pending take-profit ('limit') or stop-loss ('stop') order.
class OpenOrder {
  const OpenOrder({
    required this.id,
    required this.assetId,
    required this.orderType,
    required this.quantity,
    required this.limitPrice,
  });

  factory OpenOrder.fromJson(Map<String, dynamic> json) => OpenOrder(
        id: json['id'] as String,
        assetId: json['asset_id'] as String,
        orderType: json['order_type'] as String,
        quantity: jsonDouble(json['quantity']),
        limitPrice: jsonDouble(json['limit_price']),
      );

  final String id;
  final String assetId;
  final String orderType; // limit = take profit, stop = stop loss
  final double quantity;
  final double limitPrice;

  bool get isTakeProfit => orderType == 'limit';
}

class PortfolioRepository {
  PortfolioRepository(this._client);

  final SupabaseClient _client;

  /// Live positions via Supabase's table stream (initial rows + changes).
  Stream<List<Holding>> watchHoldings(String userId) => _client
      .from('holdings')
      .stream(primaryKey: ['user_id', 'asset_id'])
      .eq('user_id', userId)
      .map((rows) => rows.map(Holding.fromJson).toList());

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
        .select('asset_id, side, quantity, status, reject_reason, created_at')
        .order('created_at', ascending: false)
        .limit(limit);
    return rows.map(OrderRow.fromJson).toList();
  }

  Future<List<OpenOrder>> fetchOpenOrders() async {
    final rows = await _client
        .from('orders')
        .select('id, asset_id, order_type, quantity, limit_price')
        .eq('status', 'pending')
        .order('created_at', ascending: true);
    return rows.map(OpenOrder.fromJson).toList();
  }

  Future<List<NetWorthPoint>> fetchNetWorthHistory({
    Duration window = const Duration(hours: 24),
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

/// Pending TP/SL orders across all positions.
final openOrdersProvider = FutureProvider<List<OpenOrder>>(
  (ref) => ref.watch(portfolioRepositoryProvider).fetchOpenOrders(),
);
