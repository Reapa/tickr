import '../../../core/json.dart';

/// A current position, server-materialized from the trade ledger.
class Holding {
  const Holding({
    required this.assetId,
    required this.quantity,
    required this.avgCost,
  });

  factory Holding.fromJson(Map<String, dynamic> json) => Holding(
        assetId: json['asset_id'] as String,
        quantity: jsonDouble(json['quantity']),
        avgCost: jsonDouble(json['avg_cost']),
      );

  final String assetId;
  final double quantity;
  final double avgCost;

  double get costBasis => quantity * avgCost;
}

/// A row of the append-only cash/holdings ledger.
class LedgerEntry {
  const LedgerEntry({
    required this.type,
    required this.cashDelta,
    required this.assetId,
    required this.qtyDelta,
    required this.createdAt,
  });

  factory LedgerEntry.fromJson(Map<String, dynamic> json) => LedgerEntry(
        type: json['type'] as String,
        cashDelta: jsonDouble(json['cash_delta']),
        assetId: json['asset_id'] as String?,
        qtyDelta: jsonDouble(json['qty_delta']),
        createdAt: jsonDate(json['created_at']),
      );

  final String type;
  final double cashDelta;
  final String? assetId;
  final double qtyDelta;
  final DateTime createdAt;
}
