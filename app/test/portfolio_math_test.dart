import 'package:flutter_test/flutter_test.dart';
import 'package:trading_game/features/portfolio/domain/holding.dart';
import 'package:trading_game/features/portfolio/domain/portfolio_math.dart';

/// The client mirrors of the server's economy formulas. If these drift from
/// the SQL (market_tick net worth, season/challenge % return, avg-cost P&L),
/// players see numbers that disagree with the leaderboard — so they're pinned.
void main() {
  const nbla = Holding(assetId: 'nbla', quantity: 10, avgCost: 182.6825);
  const dwtn = Holding(assetId: 'dwtn', quantity: 2, avgCost: 1250);
  final prices = {'nbla': 190.0, 'dwtn': 1200.0};

  group('marketValue / netWorth', () {
    test('sums quantity times live price', () {
      expect(PortfolioMath.marketValue([nbla, dwtn], prices),
          closeTo(10 * 190 + 2 * 1200, 1e-9));
    });

    test('ignores holdings without a known price', () {
      expect(PortfolioMath.marketValue([nbla, dwtn], {'nbla': 190.0}),
          closeTo(1900, 1e-9));
    });

    test('net worth = cash + market value (mirrors market_tick)', () {
      expect(PortfolioMath.netWorth(500, [nbla], prices), closeTo(2400, 1e-9));
    });

    test('cash-only players have net worth == cash', () {
      expect(PortfolioMath.netWorth(10000, const [], const {}), 10000);
    });
  });

  group('unrealized P&L', () {
    test('profit above avg cost', () {
      expect(PortfolioMath.unrealizedPnl(nbla, 190.0),
          closeTo(10 * (190 - 182.6825), 1e-9));
    });

    test('loss below avg cost', () {
      expect(PortfolioMath.unrealizedPnl(dwtn, 1200.0), closeTo(-100, 1e-9));
    });

    test('return is P&L over cost basis', () {
      expect(PortfolioMath.unrealizedReturn(dwtn, 1200.0),
          closeTo(-100 / 2500, 1e-9));
    });

    test('zero cost basis returns zero, not NaN', () {
      const free = Holding(assetId: 'x', quantity: 5, avgCost: 0);
      expect(PortfolioMath.unrealizedReturn(free, 10), 0);
    });
  });

  group('pctReturn (challenge/season scoring formula)', () {
    test('matches the SQL formula current/start - 1', () {
      expect(PortfolioMath.pctReturn(10000, 15500), closeTo(0.55, 1e-9));
      expect(PortfolioMath.pctReturn(10000, 9000), closeTo(-0.10, 1e-9));
    });

    test('zero start guards against division by zero', () {
      expect(PortfolioMath.pctReturn(0, 5000), 0);
    });
  });

  group('sectorWeights (diversification)', () {
    test('weights sum to 1 and split by sector value', () {
      final weights = PortfolioMath.sectorWeights(
        [nbla, dwtn],
        prices,
        {'nbla': 'tech', 'dwtn': 'commercial'},
      );
      expect(weights['tech'], closeTo(1900 / 4300, 1e-9));
      expect(weights['commercial'], closeTo(2400 / 4300, 1e-9));
      expect(weights.values.reduce((a, b) => a + b), closeTo(1, 1e-9));
    });

    test('empty holdings produce empty weights', () {
      expect(PortfolioMath.sectorWeights(const [], const {}, const {}),
          isEmpty);
    });
  });

  group('maxAffordable', () {
    test('floors to whole units by default', () {
      expect(PortfolioMath.maxAffordable(1000, 182.6825), 5);
    });

    test('fractional when allowed', () {
      expect(PortfolioMath.maxAffordable(100, 40, wholeUnitsOnly: false),
          closeTo(2.5, 1e-9));
    });

    test('zero price cannot be afforded infinitely', () {
      expect(PortfolioMath.maxAffordable(1000, 0), 0);
    });
  });

  group('levelForXp (mirrors profiles.level generated column)', () {
    test('level = floor(sqrt(xp/100)) + 1', () {
      expect(PortfolioMath.levelForXp(0), 1);
      expect(PortfolioMath.levelForXp(99), 1);
      expect(PortfolioMath.levelForXp(100), 2);
      expect(PortfolioMath.levelForXp(399), 2);
      expect(PortfolioMath.levelForXp(400), 3);
      expect(PortfolioMath.levelForXp(10000), 11);
    });
  });
}
