import '../../../core/json.dart';

/// A news item. The numeric impact/volatility columns are hidden server-side:
/// players read the headline and sentiment and draw their own conclusions.
class MarketEvent {
  const MarketEvent({
    required this.id,
    required this.scope,
    required this.assetId,
    required this.sector,
    required this.headline,
    required this.body,
    required this.sentiment,
    required this.startsAt,
    required this.endsAt,
    required this.isMajor,
  });

  factory MarketEvent.fromJson(Map<String, dynamic> json) => MarketEvent(
        id: json['id'] as String,
        scope: json['scope'] as String,
        assetId: json['asset_id'] as String?,
        sector: json['sector'] as String?,
        headline: json['headline'] as String,
        body: json['body'] as String,
        sentiment: json['sentiment'] as String,
        startsAt: jsonDate(json['starts_at']),
        endsAt: jsonDate(json['ends_at']),
        isMajor: (json['is_major'] as bool?) ?? false,
      );

  final String id;
  final String scope; // asset | sector | market
  final String? assetId;
  final String? sector;
  final String headline;
  final String body;
  final String sentiment; // positive | negative | neutral
  final DateTime startsAt;
  final DateTime endsAt;

  /// A rare market-wide "major" event (war, pandemic, …) — surfaced as a banner.
  final bool isMajor;

  bool get isLive => DateTime.now().isBefore(endsAt);
}

/// One OHLC candle from the server-side aggregation (get_candles).
class Candle {
  const Candle({
    required this.bucket,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
  });

  factory Candle.fromJson(Map<String, dynamic> json) => Candle(
        bucket: jsonDate(json['bucket']),
        open: jsonDouble(json['open']),
        high: jsonDouble(json['high']),
        low: jsonDouble(json['low']),
        close: jsonDouble(json['close']),
      );

  final DateTime bucket;
  final double open;
  final double high;
  final double low;
  final double close;
}

/// A top gainer/loser row from get_movers.
class Mover {
  const Mover({
    required this.assetId,
    required this.symbol,
    required this.name,
    required this.currentPrice,
    required this.changePct,
  });

  factory Mover.fromJson(Map<String, dynamic> json) => Mover(
        assetId: json['asset_id'] as String,
        symbol: json['symbol'] as String,
        name: json['name'] as String,
        currentPrice: jsonDouble(json['current_price']),
        // change_pct is a whole-number percent (e.g. 39.47), not a fraction.
        changePct: jsonDouble(json['change_pct']) / 100,
      );

  final String assetId;
  final String symbol;
  final String name;
  final double currentPrice;
  final double changePct;
}

/// One point of price history.
class PricePoint {
  const PricePoint({required this.price, required this.time});

  factory PricePoint.fromJson(Map<String, dynamic> json) => PricePoint(
        price: jsonDouble(json['price']),
        time: jsonDate(json['tick_at']),
      );

  final double price;
  final DateTime time;
}
