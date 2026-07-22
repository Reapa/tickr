import 'package:flutter_test/flutter_test.dart';
import 'package:trading_game/core/currency.dart';
import 'package:trading_game/core/format.dart';

void main() {
  // Fmt.current is process-global; keep tests isolated.
  tearDown(() => Fmt.current = Currency.usd);

  group('Fmt currency conversion', () {
    test('USD is the identity', () {
      Fmt.current = Currency.usd;
      expect(Fmt.money(1000), r'$1,000.00');
      expect(Fmt.toUsd(1000), 1000);
      expect(Fmt.symbol, r'$');
    });

    test('converts USD amounts to the display currency', () {
      Fmt.current = currencyForCode('ZAR'); // perUsd 18.5
      expect(Fmt.money(100), 'R1,850.00');
      expect(Fmt.symbol, 'R');
    });

    test('toUsd is the inverse of the display rate (round-trips inputs)', () {
      Fmt.current = currencyForCode('ZAR');
      expect(Fmt.toUsd(1850), closeTo(100, 1e-9));
    });

    test('zero-decimal currencies drop the fraction', () {
      Fmt.current = currencyForCode('JPY'); // decimals 0, perUsd 157
      expect(Fmt.money(10), '¥1,570');
    });

    test('unknown / null code falls back to USD', () {
      expect(currencyForCode('XXX').code, 'USD');
      expect(currencyForCode(null).code, 'USD');
    });
  });
}
