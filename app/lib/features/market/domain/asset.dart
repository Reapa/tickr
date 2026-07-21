import '../../../core/json.dart';

/// A tradeable instrument as the server exposes it. Simulation internals
/// (fair value, flow, volatility parameters) are hidden at the database
/// level and deliberately absent here.
class Asset {
  const Asset({
    required this.id,
    required this.symbol,
    required this.name,
    required this.classId,
    required this.sector,
    required this.description,
    required this.currentPrice,
    required this.spread,
    required this.isActive,
  });

  factory Asset.fromJson(Map<String, dynamic> json) => Asset(
        id: json['id'] as String,
        symbol: json['symbol'] as String,
        name: json['name'] as String,
        classId: json['class_id'] as String,
        sector: json['sector'] as String,
        description: (json['description'] as String?) ?? '',
        currentPrice: jsonDouble(json['current_price']),
        spread: jsonDouble(json['spread']),
        isActive: (json['is_active'] as bool?) ?? true,
      );

  final String id;
  final String symbol;
  final String name;
  final String classId;
  final String sector;
  final String description;
  final double currentPrice;
  final double spread;
  final bool isActive;

  /// Price a market buy would fill at right now (server adds half spread).
  double get askPrice => currentPrice * (1 + spread / 2);

  /// Price a market sell would fill at right now.
  double get bidPrice => currentPrice * (1 - spread / 2);

  Asset withPrice(double price) => Asset(
        id: id,
        symbol: symbol,
        name: name,
        classId: classId,
        sector: sector,
        description: description,
        currentPrice: price,
        spread: spread,
        isActive: isActive,
      );
}

/// A progression tier (stocks -> real estate -> companies).
class AssetClass {
  const AssetClass({
    required this.id,
    required this.name,
    required this.description,
    required this.unlockCost,
    required this.isEnabled,
    required this.sortOrder,
  });

  factory AssetClass.fromJson(Map<String, dynamic> json) => AssetClass(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String,
        unlockCost: jsonDouble(json['unlock_cost']),
        isEnabled: json['is_enabled'] as bool,
        sortOrder: jsonInt(json['sort_order']),
      );

  final String id;
  final String name;
  final String description;
  final double unlockCost;
  final bool isEnabled;
  final int sortOrder;
}
