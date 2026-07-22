import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/json.dart';
import '../../../core/supabase_providers.dart';

/// Result of a server-side order attempt. Rejections are normal gameplay
/// (insufficient cash, locked class) — not exceptions.
class OrderReceipt {
  const OrderReceipt({
    required this.status,
    this.reason,
    this.price,
    this.quantity,
    this.notional,
  });

  factory OrderReceipt.fromJson(Map<String, dynamic> json) => OrderReceipt(
        status: json['status'] as String,
        reason: json['reason'] as String?,
        price: json['price'] == null ? null : jsonDouble(json['price']),
        quantity:
            json['quantity'] == null ? null : jsonDouble(json['quantity']),
        notional:
            json['notional'] == null ? null : jsonDouble(json['notional']),
      );

  final String status; // filled | rejected | unlocked
  final String? reason;
  final double? price;
  final double? quantity;
  final double? notional;

  bool get isFilled => status == 'filled';
}

/// Write side of the economy. Everything goes through SECURITY DEFINER RPCs —
/// the client never computes a price or touches a table directly.
class TradingRepository {
  TradingRepository(this._client);

  final SupabaseClient _client;

  Future<OrderReceipt> placeMarketOrder({
    required String assetId,
    required String side,
    required double quantity,
  }) async {
    final json = await _client.rpc<Map<String, dynamic>>(
      'place_market_order',
      params: {
        'p_asset_id': assetId,
        'p_side': side,
        'p_quantity': quantity,
      },
    );
    return OrderReceipt.fromJson(json);
  }

  /// Set a take-profit and/or stop-loss on a held position. The server
  /// stores them as pending sell orders the tick engine executes.
  Future<Map<String, dynamic>> setPositionProtection({
    required String assetId,
    double? takeProfit,
    double? stopLoss,
  }) =>
      _client.rpc<Map<String, dynamic>>('set_position_protection', params: {
        'p_asset_id': assetId,
        'p_take_profit': takeProfit,
        'p_stop_loss': stopLoss,
      });

  /// Queue a buy order that the tick engine fills when the price reaches a
  /// target: order_type 'limit' buys the dip (below market), 'stop' buys the
  /// breakout (above market). Cash is checked at fill, not reserved now.
  Future<OrderReceipt> placePendingOrder({
    required String assetId,
    required String orderType,
    required double quantity,
    required double limitPrice,
  }) async {
    final json = await _client.rpc<Map<String, dynamic>>(
      'place_pending_order',
      params: {
        'p_asset_id': assetId,
        'p_side': 'buy',
        'p_quantity': quantity,
        'p_order_type': orderType,
        'p_limit_price': limitPrice,
      },
    );
    return OrderReceipt.fromJson(json);
  }

  /// Set a trailing stop on a spot position: a stop-loss that ratchets toward
  /// profit as the price moves your way and never back. [trail] is a fraction
  /// when [isPercent] (0.05 = 5%), otherwise a fixed price distance.
  Future<Map<String, dynamic>> setTrailingStop({
    required String assetId,
    required double trail,
    required bool isPercent,
  }) =>
      _client.rpc<Map<String, dynamic>>('set_trailing_stop', params: {
        'p_asset_id': assetId,
        'p_trail': trail,
        'p_is_percent': isPercent,
      });

  /// Trailing stop for a leveraged position (ratchets its stop-loss level).
  Future<Map<String, dynamic>> setLeveragedTrailingStop({
    required String positionId,
    required double trail,
    required bool isPercent,
  }) =>
      _client.rpc<Map<String, dynamic>>('set_leveraged_trailing_stop', params: {
        'p_position_id': positionId,
        'p_trail': trail,
        'p_is_percent': isPercent,
      });

  Future<void> cancelPendingOrder(String orderId) =>
      _client.rpc<void>('cancel_pending_order', params: {'p_order_id': orderId});

  Future<OrderReceipt> purchaseAssetClassUnlock(String classId) async {
    final json = await _client.rpc<Map<String, dynamic>>(
      'purchase_asset_class_unlock',
      params: {'p_class_id': classId},
    );
    return OrderReceipt.fromJson(json);
  }
}

final tradingRepositoryProvider = Provider<TradingRepository>(
  (ref) => TradingRepository(ref.watch(supabaseProvider)),
);
