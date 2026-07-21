import 'holding.dart';

/// Pure portfolio arithmetic. The server's numbers are authoritative — these
/// mirror its formulas for display (P&L badges, allocation, projections) and
/// are unit-tested to stay consistent with the SQL.
abstract final class PortfolioMath {
  /// Market value of a set of holdings given current prices.
  /// Holdings whose price is unknown contribute nothing.
  static double marketValue(
    List<Holding> holdings,
    Map<String, double> priceByAssetId,
  ) {
    var total = 0.0;
    for (final h in holdings) {
      final price = priceByAssetId[h.assetId];
      if (price != null) total += h.quantity * price;
    }
    return total;
  }

  /// Net worth = cash + marked-to-market holdings (mirrors market_tick()).
  static double netWorth(
    double cash,
    List<Holding> holdings,
    Map<String, double> priceByAssetId,
  ) =>
      cash + marketValue(holdings, priceByAssetId);

  /// Unrealized P&L for one position.
  static double unrealizedPnl(Holding holding, double currentPrice) =>
      holding.quantity * (currentPrice - holding.avgCost);

  /// Unrealized return as a fraction of cost basis (0.05 == +5%).
  static double unrealizedReturn(Holding holding, double currentPrice) {
    if (holding.costBasis == 0) return 0;
    return unrealizedPnl(holding, currentPrice) / holding.costBasis;
  }

  /// % return between two net worths (challenge/season scoring formula).
  static double pctReturn(double startNetWorth, double currentNetWorth) {
    if (startNetWorth == 0) return 0;
    return currentNetWorth / startNetWorth - 1;
  }

  /// Distinct-sector allocation weights, for the diversification UI.
  /// Returns sector -> fraction of holdings value (empty if no value).
  static Map<String, double> sectorWeights(
    List<Holding> holdings,
    Map<String, double> priceByAssetId,
    Map<String, String> sectorByAssetId,
  ) {
    final bySector = <String, double>{};
    for (final h in holdings) {
      final price = priceByAssetId[h.assetId];
      final sector = sectorByAssetId[h.assetId];
      if (price == null || sector == null) continue;
      bySector[sector] = (bySector[sector] ?? 0) + h.quantity * price;
    }
    final total = bySector.values.fold(0.0, (a, b) => a + b);
    if (total == 0) return const {};
    return bySector.map((sector, value) => MapEntry(sector, value / total));
  }

  /// Maximum affordable quantity for a cash balance at an ask price, in
  /// whole units below [wholeUnitsOnly]=true (the UI default).
  static double maxAffordable(
    double cash,
    double askPrice, {
    bool wholeUnitsOnly = true,
  }) {
    if (askPrice <= 0) return 0;
    final raw = cash / askPrice;
    return wholeUnitsOnly ? raw.floorToDouble() : raw;
  }

  /// The XP -> level curve, mirroring the profiles.level generated column:
  /// level = floor(sqrt(xp / 100)) + 1.
  static int levelForXp(int xp) {
    if (xp <= 0) return 1;
    var level = 1;
    while (100 * level * level <= xp) {
      level += 1;
    }
    return level;
  }
}
