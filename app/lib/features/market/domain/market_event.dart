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

  bool get isLive => DateTime.now().isBefore(endsAt);
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
