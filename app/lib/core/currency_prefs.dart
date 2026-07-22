import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/market/data/market_repository.dart';
import 'currency.dart';
import 'format.dart';
import 'prefs.dart';

/// The player's chosen display currency, persisted across sessions. Keeps
/// [Fmt.current] in sync (and seeds [Fmt.rate] from the fallback) so formatting
/// is correct even at call sites that don't watch this provider.
class CurrencyNotifier extends Notifier<Currency> {
  static const _kCode = 'display.currency';

  @override
  Currency build() {
    final code = ref.read(sharedPreferencesProvider).getString(_kCode);
    final currency = currencyForCode(code);
    Fmt.current = currency;
    Fmt.rate = currency.fallbackPerUsd;
    return currency;
  }

  void setCurrency(Currency currency) {
    ref.read(sharedPreferencesProvider).setString(_kCode, currency.code);
    Fmt.current = currency;
    // Show the fallback immediately; displayRateProvider refines to the live
    // forex rate on the next read/tick.
    Fmt.rate = currency.fallbackPerUsd;
    state = currency;
  }
}

final currencyProvider =
    NotifierProvider<CurrencyNotifier, Currency>(CurrencyNotifier.new);

/// The live display-units-per-USD rate, derived from the chosen currency's
/// forex pair price in [assetsProvider]. Recomputes as the pair trades and
/// pushes the result into [Fmt.rate] so the static formatter stays current.
final displayRateProvider = Provider<double>((ref) {
  final currency = ref.watch(currencyProvider);
  double rate;
  if (currency.pairSymbol == null) {
    rate = 1;
  } else {
    final pair = (ref.watch(assetsProvider).value ?? const [])
        .where((a) => a.symbol == currency.pairSymbol)
        .firstOrNull;
    rate = pair == null
        ? currency.fallbackPerUsd
        : perUsdFromPair(currency, pair.currentPrice);
  }
  Fmt.rate = rate;
  return rate;
});
