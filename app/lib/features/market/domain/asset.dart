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
    required this.marketHours,
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
        marketHours: (json['market_hours'] as String?) ?? 'weekday_day',
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

  /// '24_7' (crypto), '24_5' (forex), or 'weekday_day' (stocks / real estate).
  final String marketHours;

  /// Price a market buy would fill at right now (server adds half spread).
  double get askPrice => currentPrice * (1 + spread / 2);

  /// Price a market sell would fill at right now.
  double get bidPrice => currentPrice * (1 - spread / 2);

  /// Whether this market is currently open. Display-only mirror of the
  /// server's game.is_market_open() — the server still authoritatively
  /// rejects any order placed against a closed market. Ignores the
  /// markets_always_open dev override (which is off in production).
  bool get isMarketOpenNow {
    final now = DateTime.now().toUtc();
    final dow = now.weekday; // 1=Mon .. 7=Sun
    final hr = now.hour;
    switch (marketHours) {
      case '24_7':
        return true;
      case '24_5':
        // Closed Fri 22:00 UTC -> Sun 22:00 UTC.
        return !(dow == 6 || (dow == 5 && hr >= 22) || (dow == 7 && hr < 22));
      case 'weekday_day':
        return dow <= 5 && hr >= 6 && hr < 22;
      default:
        return true;
    }
  }

  String get marketHoursLabel => switch (marketHours) {
        '24_7' => '24/7',
        '24_5' => '24/5',
        _ => 'Mon–Fri 06:00–22:00 UTC',
      };

  /// Short human hint for when a closed market reopens.
  String get reopensHint => switch (marketHours) {
        '24_5' => 'Reopens Sunday 22:00 UTC',
        'weekday_day' => 'Trades weekdays 06:00–22:00 UTC',
        _ => '',
      };

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
        marketHours: marketHours,
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
