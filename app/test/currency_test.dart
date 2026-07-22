import 'package:flutter_test/flutter_test.dart';
import 'package:trading_game/core/currency.dart';
import 'package:trading_game/core/format.dart';

void main() {
  // Fmt.current / Fmt.rate are process-global; keep tests isolated.
  tearDown(() {
    Fmt.current = Currency.usd;
    Fmt.rate = 1;
  });

  group('Fmt formatting at a rate', () {
    test('USD is the identity', () {
      Fmt.current = Currency.usd;
      Fmt.rate = 1;
      expect(Fmt.money(1000), r'$1,000.00');
      expect(Fmt.toUsd(1000), 1000);
      expect(Fmt.symbol, r'$');
    });

    test('converts USD amounts at the live rate, with the symbol', () {
      Fmt.current = currencyForCode('ZAR');
      Fmt.rate = 18.5;
      expect(Fmt.money(100), 'R1,850.00');
      expect(Fmt.symbol, 'R');
    });

    test('toUsd is the inverse of the rate (round-trips inputs)', () {
      Fmt.rate = 18.5;
      expect(Fmt.toUsd(1850), closeTo(100, 1e-9));
    });

    test('zero-decimal currencies drop the fraction', () {
      Fmt.current = currencyForCode('JPY');
      Fmt.rate = 148.5;
      expect(Fmt.money(10), '¥1,485');
    });
  });

  group('perUsdFromPair (rate from the forex market)', () {
    test('USD-per-foreign pairs invert (EURUSD 1.08 -> ~0.926/USD)', () {
      expect(perUsdFromPair(currencyForCode('EUR'), 1.08), closeTo(1 / 1.08, 1e-9));
    });
    test('foreign-per-USD pairs pass through (USDZAR 18.7 -> 18.7/USD)', () {
      expect(perUsdFromPair(currencyForCode('ZAR'), 18.7), 18.7);
    });
    test('a non-positive price falls back', () {
      final zar = currencyForCode('ZAR');
      expect(perUsdFromPair(zar, 0), zar.fallbackPerUsd);
    });
    test('USD is always 1', () {
      expect(perUsdFromPair(Currency.usd, 123), 1);
    });
  });

  test('unknown / null code falls back to USD', () {
    expect(currencyForCode('XXX').code, 'USD');
    expect(currencyForCode(null).code, 'USD');
  });
}
