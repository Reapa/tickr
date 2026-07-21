import '../../../core/json.dart';

/// A CFD-style leveraged position. Max loss is always the posted margin.
class LeveragedPosition {
  const LeveragedPosition({
    required this.id,
    required this.assetId,
    required this.side,
    required this.leverage,
    required this.quantity,
    required this.entryPrice,
    required this.margin,
    required this.liquidationPrice,
    required this.takeProfit,
    required this.stopLoss,
    required this.status,
    required this.realizedPnl,
    required this.closeReason,
  });

  factory LeveragedPosition.fromJson(Map<String, dynamic> json) =>
      LeveragedPosition(
        id: json['id'] as String,
        assetId: json['asset_id'] as String,
        side: json['side'] as String,
        leverage: jsonInt(json['leverage']),
        quantity: jsonDouble(json['quantity']),
        entryPrice: jsonDouble(json['entry_price']),
        margin: jsonDouble(json['margin']),
        liquidationPrice: jsonDouble(json['liquidation_price']),
        takeProfit: json['take_profit'] == null
            ? null
            : jsonDouble(json['take_profit']),
        stopLoss:
            json['stop_loss'] == null ? null : jsonDouble(json['stop_loss']),
        status: json['status'] as String,
        realizedPnl: json['realized_pnl'] == null
            ? null
            : jsonDouble(json['realized_pnl']),
        closeReason: json['close_reason'] as String?,
      );

  final String id;
  final String assetId;
  final String side; // long | short
  final int leverage;
  final double quantity;
  final double entryPrice;
  final double margin;
  final double liquidationPrice;
  final double? takeProfit;
  final double? stopLoss;
  final String status; // open | closed | liquidated
  final double? realizedPnl;
  final String? closeReason;

  bool get isLong => side == 'long';
  bool get isOpen => status == 'open';

  /// Unrealized P&L at [markPrice] (the bid for longs, ask for shorts).
  double pnlAt(double markPrice) => isLong
      ? quantity * (markPrice - entryPrice)
      : quantity * (entryPrice - markPrice);

  /// P&L as a fraction of margin (what leverage players actually feel).
  double returnOnMarginAt(double markPrice) =>
      margin == 0 ? 0 : pnlAt(markPrice) / margin;

  /// 0 = at entry, 1 = at liquidation. Drives the danger meter.
  double liquidationProgressAt(double markPrice) {
    final total = (entryPrice - liquidationPrice).abs();
    if (total == 0) return 1;
    final gone = isLong ? entryPrice - markPrice : markPrice - entryPrice;
    return (gone / total).clamp(0.0, 1.0);
  }
}
