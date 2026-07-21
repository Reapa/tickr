import 'package:flutter_test/flutter_test.dart';
import 'package:trading_game/core/json.dart';
import 'package:trading_game/features/market/domain/asset.dart';
import 'package:trading_game/features/market/domain/market_event.dart';
import 'package:trading_game/features/portfolio/domain/holding.dart';
import 'package:trading_game/features/profile/domain/profile.dart';

void main() {
  group('json coercion', () {
    test('accepts numbers and numeric strings', () {
      expect(jsonDouble(182.5), 182.5);
      expect(jsonDouble('182.5000'), 182.5);
      expect(jsonDouble(null), 0);
      expect(jsonInt('7'), 7);
      expect(jsonInt(7.0), 7);
    });
  });

  group('Asset', () {
    final asset = Asset.fromJson({
      'id': 'a1',
      'symbol': 'NBLA',
      'name': 'Nebula Systems',
      'class_id': 'stocks',
      'sector': 'tech',
      'description': 'test',
      'current_price': 182.50,
      'spread': 0.002,
      'is_active': true,
    });

    test('parses server row', () {
      expect(asset.symbol, 'NBLA');
      expect(asset.currentPrice, 182.50);
    });

    test('ask/bid bracket the mid by half the spread (matches server fill)',
        () {
      expect(asset.askPrice, closeTo(182.6825, 1e-9));
      expect(asset.bidPrice, closeTo(182.3175, 1e-9));
    });

    test('withPrice preserves identity, moves price', () {
      final moved = asset.withPrice(200);
      expect(moved.currentPrice, 200);
      expect(moved.symbol, asset.symbol);
      expect(moved.spread, asset.spread);
      expect(moved.marketHours, asset.marketHours);
    });

    test('market_hours defaults to weekday_day when absent', () {
      expect(asset.marketHours, 'weekday_day');
    });

    test('24/7 markets are always open', () {
      final crypto = Asset.fromJson({
        'id': 'c1',
        'symbol': 'BTCN',
        'name': 'Bitcorn',
        'class_id': 'crypto',
        'sector': 'crypto',
        'current_price': 67500.0,
        'spread': 0.001,
        'is_active': true,
        'market_hours': '24_7',
      });
      expect(crypto.isMarketOpenNow, isTrue);
      expect(crypto.marketHoursLabel, '24/7');
    });
  });

  group('Mover', () {
    test('change_pct is stored as a fraction (server sends whole percent)', () {
      final m = Mover.fromJson({
        'asset_id': 'a1',
        'symbol': 'NIKY',
        'name': 'Nikey',
        'current_price': 94.4,
        'change_pct': 39.47,
      });
      expect(m.changePct, closeTo(0.3947, 1e-9));
      expect(m.symbol, 'NIKY');
    });
  });

  group('Holding', () {
    test('cost basis = qty * avg cost', () {
      const h = Holding(assetId: 'x', quantity: 6, avgCost: 182.6825);
      expect(h.costBasis, closeTo(1096.095, 1e-9));
    });
  });

  group('Profile', () {
    final profile = Profile.fromJson({
      'id': 'u1',
      'display_name': 'Alice',
      'friend_code': 'TG-ABC123',
      'cash_balance': '8423.17',
      'net_worth': 10000,
      'xp': 150,
      'level': 2,
      'premium_balance': 200,
      'equipped': {'avatar_frame': 'frame_gold'},
    });

    test('parses numerics defensively (string or number)', () {
      expect(profile.cashBalance, 8423.17);
      expect(profile.netWorth, 10000);
    });

    test('level progress is within the current band', () {
      // Level 2 spans 100..400 XP; 150 XP is 1/6 through.
      expect(profile.levelProgress, closeTo((150 - 100) / 300, 1e-9));
    });
  });
}
